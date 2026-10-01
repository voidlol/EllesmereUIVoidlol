-------------------------------------------------------------------------------
--  EllesmereUIVoidlol_Tooltip.lua
--  Tooltip enhancements. Currently: a health bar under unit tooltips.
--
--  The bar is our OWN frame parented to GameTooltip, never Blizzard's
--  GameTooltipStatusBar (EllesmereUIBlizzardSkin already alpha-hides that one
--  and hooks its Show). Parenting means it hides and scales with the tooltip
--  for free; it's shown from the Unit tooltip post-call and hidden on
--  OnTooltipCleared, so item/spell tooltips never carry a stale bar.
--
--  Midnight secret values: UnitHealth/UnitHealthMax/UnitHealthPercent can be
--  secret. They're only ever handed straight to StatusBar setters,
--  AbbreviateNumbers and string.format -- all secret-aware -- never compared
--  or used in arithmetic (same approach as EllesmereUIUnitFrames' text tags).
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EVL = ns.EVL

local BLIZZARD_BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local UPDATE_INTERVAL = 0.1
local BAR_GAP = 2 -- space between the tooltip's bottom edge and the bar

local issecret = issecretvalue or function() return false end

local function DB()
    local d = EVL.DB and EVL.DB()
    local q = d and d.qol
    return q and q.tooltip
end

local function Enabled()
    local cfg = DB()
    return cfg and cfg.healthBarEnabled
end

local function GetFontPath(fontKey)
    if fontKey == "__global" or not fontKey then
        return (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
    end
    return (EllesmereUI.ResolveFontName and EllesmereUI.ResolveFontName(fontKey)) or "Fonts\\FRIZQT__.TTF"
end

local function GetBarTexturePath(key)
    if not key or key == "Blizzard" then return BLIZZARD_BAR_TEXTURE end
    local smName = key:match("^sm:(.+)")
    if smName then
        local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
        local fetched = LSM and LSM:Fetch("statusbar", smName, true)
        if fetched then return fetched end
    end
    return BLIZZARD_BAR_TEXTURE
end

-------------------------------------------------------------------------------
--  Unit resolution
--  GetUnit() can hand back a secret token (e.g. secure raid-frame tooltips)
--  even when the GUID is clean; fall back to UnitTokenFromGUID, then to
--  "mouseover" only when it provably is the same unit.
-------------------------------------------------------------------------------
local function ResolveUnit(tt, data)
    local ok, _, unit = pcall(tt.GetUnit, tt)
    if ok and unit and not issecret(unit) and UnitExists(unit) then
        return unit
    end
    local guid = data and data.guid
    if not guid or issecret(guid) then return nil end
    if UnitTokenFromGUID then
        local tu = UnitTokenFromGUID(guid)
        if tu and not issecret(tu) and UnitExists(tu) then return tu end
    end
    if UnitExists("mouseover") then
        local mg = UnitGUID("mouseover")
        if mg and not issecret(mg) and mg == guid then return "mouseover" end
    end
    return nil
end

-------------------------------------------------------------------------------
--  Text / color
-------------------------------------------------------------------------------
local function Abbrev(v)
    return AbbreviateNumbers and AbbreviateNumbers(v) or tostring(v)
end

local function PercentText(unit)
    if UnitHealthPercent and CurveConstants and CurveConstants.ScaleTo100 then
        local pct = UnitHealthPercent(unit, true, CurveConstants.ScaleTo100)
        if pct then return string.format("%d%%", pct) end
    end
    local hp, maxHp = UnitHealth(unit), UnitHealthMax(unit)
    if issecret(hp) or issecret(maxHp) or not maxHp or maxHp == 0 then return "" end
    return string.format("%d%%", hp / maxHp * 100)
end

local function BuildText(unit, fmt)
    if not UnitIsConnected(unit) then return "Offline" end
    if UnitIsDeadOrGhost(unit) then return "Dead" end
    if fmt == "percent" then
        return PercentText(unit)
    elseif fmt == "current" then
        return Abbrev(UnitHealth(unit))
    elseif fmt == "currentmax" then
        return string.format("%s / %s", Abbrev(UnitHealth(unit)), Abbrev(UnitHealthMax(unit)))
    end
    -- "currentpercent" (default)
    return string.format("%s | %s", Abbrev(UnitHealth(unit)), PercentText(unit))
end

local function GetUnitColor(unit, cfg)
    if cfg.colorMode == "custom" then
        return cfg.colorR or 0.2, cfg.colorG or 0.8, cfg.colorB or 0.2
    end
    if UnitIsPlayer(unit) then
        local _, classFile = UnitClass(unit)
        local cc = classFile and not issecret(classFile) and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
        if cc then return cc.r, cc.g, cc.b end
    else
        local tapDenied = UnitIsTapDenied and UnitIsTapDenied(unit)
        if not issecret(tapDenied) and tapDenied then return 0.5, 0.5, 0.5 end
        local reaction = UnitReaction(unit, "player")
        local fc = reaction and not issecret(reaction) and FACTION_BAR_COLORS and FACTION_BAR_COLORS[reaction]
        if fc then return fc.r, fc.g, fc.b end
    end
    return 0.2, 0.8, 0.2
end

-------------------------------------------------------------------------------
--  Bar frame
-------------------------------------------------------------------------------
local holder, bar, text
local currentUnit
local elapsedSinceUpdate = 0

local function UpdateValues()
    local unit = currentUnit
    local cfg = DB()
    if not (unit and cfg and holder) then return end
    -- Unit gone (e.g. mouseover moved off while the tooltip fades): keep
    -- showing the last reading rather than blanking a fading tooltip.
    if not UnitExists(unit) then return end

    bar:SetMinMaxValues(0, UnitHealthMax(unit))
    if UnitIsDeadOrGhost(unit) then
        bar:SetValue(0)
    else
        bar:SetValue(UnitHealth(unit))
    end
    bar:SetStatusBarColor(GetUnitColor(unit, cfg))

    if cfg.showText then
        text:SetText(BuildText(unit, cfg.textFormat))
        text:Show()
    else
        text:Hide()
    end
end

local function ApplyStyle()
    local cfg = DB()
    if not (cfg and holder) then return end

    holder:SetHeight((cfg.height or 8) + 2) -- +1px border on each side
    bar:SetStatusBarTexture(GetBarTexturePath(cfg.texture))

    local font = GetFontPath(cfg.fontFace)
    local flags = cfg.outline ~= false and "OUTLINE" or ""
    if not text:SetFont(font, cfg.fontSize or 11, flags) then
        text:SetFont("Fonts\\FRIZQT__.TTF", cfg.fontSize or 11, flags)
    end
    text:SetTextColor(cfg.textColorR or 1, cfg.textColorG or 1, cfg.textColorB or 1)

    text:ClearAllPoints()
    local align = cfg.textAlign or "CENTER"
    if align == "LEFT" then
        text:SetPoint("LEFT", bar, "LEFT", 3, 0)
    elseif align == "RIGHT" then
        text:SetPoint("RIGHT", bar, "RIGHT", -3, 0)
    else
        text:SetPoint("CENTER", bar, "CENTER", 0, 0)
    end
    text:SetJustifyH(align)
end

local function EnsureFrames()
    if holder then return end

    holder = CreateFrame("Frame", nil, GameTooltip)
    holder:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 0, -BAR_GAP)
    holder:SetPoint("TOPRIGHT", GameTooltip, "BOTTOMRIGHT", 0, -BAR_GAP)
    holder:Hide()

    local border = holder:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(0, 0, 0, 1)

    bar = CreateFrame("StatusBar", nil, holder)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("BOTTOMRIGHT", -1, 1)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.08, 0.08, 0.08, 0.9)

    text = bar:CreateFontString(nil, "OVERLAY")
    text:SetWordWrap(false)

    holder:SetScript("OnUpdate", function(_, elapsed)
        elapsedSinceUpdate = elapsedSinceUpdate + elapsed
        if elapsedSinceUpdate < UPDATE_INTERVAL then return end
        elapsedSinceUpdate = 0
        UpdateValues()
    end)

    ApplyStyle()
end

local function HideBar()
    currentUnit = nil
    if holder then holder:Hide() end
end

local function OnUnitTooltip(tt, data)
    if tt ~= GameTooltip or not Enabled() then return end
    if tt.IsForbidden and tt:IsForbidden() then return end
    local unit = ResolveUnit(tt, data)
    if not unit then HideBar(); return end

    EnsureFrames()
    currentUnit = unit
    elapsedSinceUpdate = 0
    UpdateValues()
    holder:Show()
end

local hooked = false
local function EnsureHooks()
    if hooked then return end
    if not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType) then
        return
    end
    hooked = true
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
    -- HookScript, never SetScript: keeps Blizzard's own handlers intact.
    GameTooltip:HookScript("OnTooltipCleared", HideBar)
end

function EVL.ApplyTooltip()
    if Enabled() then
        EnsureHooks()
        if holder then
            ApplyStyle()
            UpdateValues()
        end
    else
        -- Hooks can't be removed; they early-out on Enabled() instead.
        HideBar()
    end
end
