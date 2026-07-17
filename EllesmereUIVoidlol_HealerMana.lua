-------------------------------------------------------------------------------
--  EllesmereUIVoidlol_HealerMana.lua
--  Shows mana% (+ spec icon + name) for your group's/raid's healers. Two
--  independent containers -- "Healer Mana (Party)" and "Healer Mana (Raid)"
--  -- each separately positionable via EllesmereUI Unlock Mode, mirroring
--  EllesmereUIVoidlol_CombatText.lua's two-frame pattern.
--
--  Design notes (deviations from the reference implementation):
--   - Mana/connection refresh is fully event-driven: UNIT_POWER_UPDATE,
--     UNIT_POWER_FREQUENT (fires repeatedly during fast regen/decay -- NOT
--     "UNIT_POWER_FREQUENT_UPDATE", which isn't a registerable event and
--     errored on UnregisterEvent in an earlier version of this file), and
--     UNIT_CONNECTION, RegisterUnitEvent'd per currently-tracked healer unit
--     and re-synced whenever the healer list changes. No wall-clock timer.
--   - Two preview surfaces: (1) Unlock Mode visibility doubles as a live,
--     drag-to-position preview -- while Unlock Mode is open, both containers
--     show sample healer rows, like CombatText's placeholder text. This one
--     requires "Enabled" to be on (matches CombatText's own gate). (2) The
--     options page itself always shows one sample row (EVL.HealerMana_Create
--     PreviewRow/StylePreviewRow, called from EUI_Voidlol_Options.lua),
--     regardless of Enabled/Unlock Mode, so settings changes are visible
--     immediately without needing to enable the feature or open Unlock Mode.
--   - Spec icon accuracy uses the same queued NotifyInspect/GetInspectSpecialization
--     flow every inspect-based addon uses (not secure/tainted, just throttled).
--   - Global font settings (font/size) apply to both name and mana text; the
--     configurable color applies to the mana% text only -- names stay
--     class-colored (matches how cast-target text is handled elsewhere).
--   - Icon size and name-length-limit are both live settings (cfg.iconSize,
--     cfg.nameMaxLength) rather than fixed constants; row/container sizing is
--     computed from the current icon size on every apply.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EVL = ns.EVL

local CONTAINER_DEFS = {
    { key = "party", unlockKey = "EVL_HealerMana_Party", label = "Healer Mana (Party)" },
    { key = "raid",  unlockKey = "EVL_HealerMana_Raid",  label = "Healer Mana (Raid)" },
}

local containers   = {}                         -- key -> anchor frame (lazy)
local rowPools     = { party = {}, raid = {} }   -- key -> pooled row frames
local activeRows   = { party = {}, raid = {} }   -- key -> active row frames, index-aligned to currentHealers[key]
local currentHealers = { party = {}, raid = {} } -- key -> { unit, guid, name, class, colorR/G/B, connected, frameIndex, specID }

local runtimeFrame
local unlockHooksInstalled = false
local unlockRegistered = false
-- True while Unlock Mode is open and we're showing an empty positioning stub
-- instead of real content (see ShowUnlockStub below) -- NOT a content preview.
local unlockStubActive = false

local inspectQueue = {}
local currentInspect
local specCache = {}

local FALLBACK_ICON = 135915
-- Used only by the options-page standalone preview (EVL.HealerMana_GetRandomPreviewSample) --
-- Unlock Mode itself shows an empty stub, no sample spec/name/mana content.
local PREVIEW_SPECS = { 105, 270, 65, 256, 257, 264, 1468 } -- Resto Druid, Mistweaver, Holy Pala, Disc, Holy Priest, Resto Sham, Preservation
-- Deliberately long fake names so the name-length-limit setting is visibly
-- demonstrated in the preview, not just theoretical.
local PREVIEW_NAMES = { "Thunderstrikeus", "Moonshadowblade", "Emberheartsong" }
local INSPECT_DELAY = 0.05

local DEFAULT_ICON_SIZE = 24
local ICON_GAP          = 4
local ROW_SPACING       = 3

-------------------------------------------------------------------------------
--  Forward declarations -- every function referenced by a closure defined
--  before its own body must be declared here first (see EllesmereUIVoidlol_
--  QuickFocus.lua's HookFrame/AnnounceFocusMarkOnReadyCheck fix for why: a
--  name used inside an earlier closure without this resolves to a nil global
--  and errors at runtime the first time that closure fires).
-------------------------------------------------------------------------------
local EnsureContainer
local ApplyPosition
local LayoutRows
local UpdateContainerSize
local CreateHealerRow
local AcquireRow
local ReleaseAllRows
local ApplyRowStyle
local UpdateManaDisplay
local RefreshHealerRow
local AddHealer
local GetHealerByGUID
local FindHealerByUnit
local QueueInspect
local ProcessInspectQueue
local OnInspectReady
local ClearInspectQueue
local RefreshHealerIcon
local RefreshContainer
local SyncUnitEvents
local FindHealers
local OnSpecChanged
local ShowUnlockStub
local ShowUnlockStubs
local HideAllFrames
local EnableRuntime
local DisableRuntime
local TryHookUnlockFrame
local RegisterUnlock
local ApplyAll

-------------------------------------------------------------------------------
--  DB / small leaf helpers
-------------------------------------------------------------------------------
local function DB()
    local d = EVL.DB and EVL.DB()
    return d and d.healerMana
end

local function GetPosKey(key)
    return key == "party" and "partyPos" or "raidPos"
end

local function GetFontPath(fontKey)
    if fontKey == "__global" then
        return (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
    end
    return (EllesmereUI.ResolveFontName and EllesmereUI.ResolveFontName(fontKey)) or "Fonts\\FRIZQT__.TTF"
end

local function GetClassColor(classToken)
    if EllesmereUI.GetClassColor then
        local c = EllesmereUI.GetClassColor(classToken)
        if c then return c.r, c.g, c.b end
    end
    if C_ClassColor and C_ClassColor.GetClassColor then
        local c = C_ClassColor.GetClassColor(classToken)
        if c then return c:GetRGB() end
    end
    return 1, 1, 1
end

local function GetManaPercent(unit)
    return UnitPowerPercent(unit, Enum.PowerType.Mana, true, CurveConstants.ScaleTo100)
end

-- No gradient: ColorCurve:Evaluate() rejects a secret x from addon (tainted)
-- code on this client ("Secret values are only allowed during untainted
-- execution for this argument") -- confirmed twice now, including with the
-- exact construction shape Blizzard's own Curve examples use, so it isn't a
-- construction-shape issue. Reaching pct/100-style arithmetic on a secret
-- value errors too (confirmed in earlier attempts). So there's no addon-side
-- way to derive a gradient color from another healer's secret mana% --
-- pct just gets a flat default (white) unless the user picked a custom color.
local function GetManaTextColor(pct)
    local cfg = DB()
    if cfg and cfg.useCustomManaColor then
        return cfg.manaColorR or 1, cfg.manaColorG or 1, cfg.manaColorB or 1, 1
    end
    return 1, 1, 1, 1
end

local function GetIconSize()
    local cfg = DB()
    local size = cfg and cfg.iconSize
    if type(size) ~= "number" then return DEFAULT_ICON_SIZE end
    return size
end

local function IsIconShown()
    local cfg = DB()
    return not cfg or cfg.showIcon ~= false
end

-- maxLen <= 0 (or unset) means unlimited, matching the options slider's "0 = Unlimited".
local function TruncateHealerName(name)
    if not name then return "" end
    local cfg = DB()
    local maxLen = cfg and cfg.nameMaxLength
    if not maxLen or maxLen <= 0 or #name <= maxLen then return name end
    return name:sub(1, maxLen)
end

-------------------------------------------------------------------------------
--  Dynamic text-column width: measures ACTUAL pixel width at the current
--  font/size (via a hidden, reused measuring FontString), instead of a fixed
--  constant, so the frame is only ever as wide as it needs to be.
-------------------------------------------------------------------------------
local measureFS

local function MeasureTextWidth(text, fontPath, fontSize)
    if not measureFS then
        local host = CreateFrame("Frame", nil, UIParent)
        host:Hide()
        measureFS = host:CreateFontString(nil, "OVERLAY")
    end
    measureFS:SetFont(fontPath, fontSize, "OUTLINE")
    measureFS:SetText(text or "")
    return measureFS:GetStringWidth() or 0
end

-- `names`: array of already-truncated display names currently shown in this
-- row group. Only consulted when nameMaxLength is unlimited (0), to size
-- against the actual longest name; when a max length is set, the worst-case
-- width (maxLen "M" characters, a representatively wide glyph) is used
-- instead, so the column doesn't jitter in width as different healers with
-- different-length names cycle through.
local function ComputeTextColumnWidth(names)
    local cfg = DB()
    local fontPath = GetFontPath(cfg and cfg.fontFace or "__global")
    local fontSize = (cfg and cfg.fontSize) or 12
    local maxLen = cfg and cfg.nameMaxLength

    local nameW
    if maxLen and maxLen > 0 then
        nameW = MeasureTextWidth(string.rep("M", maxLen), fontPath, fontSize)
    else
        nameW = 0
        for _, name in ipairs(names or {}) do
            local w = MeasureTextWidth(name, fontPath, fontSize)
            if w > nameW then nameW = w end
        end
    end

    local manaW = MeasureTextWidth("100%", fontPath, fontSize)
    return math.max(nameW, manaW)
end

local function GetRowWidth(textColumnWidth)
    if not IsIconShown() then return textColumnWidth or 0 end
    return GetIconSize() + ICON_GAP + (textColumnWidth or 0)
end

-------------------------------------------------------------------------------
--  Container (per-group-type anchor frame)
-------------------------------------------------------------------------------
EnsureContainer = function(key)
    if containers[key] then return containers[key] end
    local def
    for _, d in ipairs(CONTAINER_DEFS) do
        if d.key == key then def = d break end
    end
    if not def then return nil end

    local frame = CreateFrame("Frame", "EllesmereUIVoidlol_HealerMana_" .. key, UIParent)
    frame:SetSize(GetRowWidth(0), GetIconSize()) -- placeholder; corrected by the first RefreshContainer/ShowUnlockStub
    frame:Hide()
    containers[key] = frame
    return frame
end

ApplyPosition = function(key)
    local cfg = DB()
    local container = containers[key]
    if not cfg or not container then return end

    container:ClearAllPoints()
    local pos = cfg[GetPosKey(key)]
    if pos then
        container:SetPoint("CENTER", UIParent, "CENTER", pos.centerX, pos.centerY)
    else
        container:SetPoint("CENTER", UIParent, "CENTER", key == "party" and -250 or 250, 0)
    end
end

-- Growth direction: party always stacks vertically; raid respects the
-- configurable dropdown. Only raid exposes the option (per spec).
LayoutRows = function(key, textColumnWidth)
    local cfg = DB()
    local container = containers[key]
    local rows = activeRows[key]
    if not cfg or not container or not rows then return end

    local direction = (key == "raid") and (cfg.raidGrowDirection or "VERTICAL") or "VERTICAL"
    local iconSize = GetIconSize()
    local rowWidth = GetRowWidth(textColumnWidth)

    for i, row in ipairs(rows) do
        row:ClearAllPoints()
        if direction == "HORIZONTAL" then
            row:SetPoint("TOPLEFT", container, "TOPLEFT", (i - 1) * (rowWidth + ROW_SPACING), 0)
        else
            row:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * (iconSize + ROW_SPACING)))
        end
    end
end

UpdateContainerSize = function(key, textColumnWidth)
    local cfg = DB()
    local container = containers[key]
    if not cfg or not container then return end

    local iconSize = GetIconSize()
    local rowWidth = GetRowWidth(textColumnWidth)

    local count = #activeRows[key]
    if count == 0 then
        container:SetSize(rowWidth, iconSize)
        return
    end

    local direction = (key == "raid") and (cfg.raidGrowDirection or "VERTICAL") or "VERTICAL"
    if direction == "HORIZONTAL" then
        container:SetSize((rowWidth * count) + (ROW_SPACING * (count - 1)), iconSize)
    else
        container:SetSize(rowWidth, (iconSize * count) + (ROW_SPACING * (count - 1)))
    end
end

-------------------------------------------------------------------------------
--  Row frames (icon + name + mana%), pooled per container
-------------------------------------------------------------------------------
CreateHealerRow = function(container)
    local row = CreateFrame("Frame", nil, container)
    row:SetSize(GetRowWidth(0), GetIconSize()) -- placeholder; ApplyRowStyle corrects it immediately after acquire

    local iconFrame = CreateFrame("Frame", nil, row)
    iconFrame:SetSize(GetIconSize(), GetIconSize())
    iconFrame:SetPoint("LEFT", row, "LEFT", 0, 0)
    local iconBg = iconFrame:CreateTexture(nil, "BACKGROUND")
    iconBg:SetAllPoints()
    iconBg:SetColorTexture(0, 0, 0, 1)
    local PP = EllesmereUI and EllesmereUI.PP
    if PP and PP.CreateBorder then PP.CreateBorder(iconFrame, 0, 0, 0, 1) end
    local iconTex = iconFrame:CreateTexture(nil, "ARTWORK")
    iconTex:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 1, -1)
    iconTex:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -1, 1)
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.iconFrame = iconFrame
    row.icon = iconTex

    local nameFS = row:CreateFontString(nil, "OVERLAY")
    nameFS:SetPoint("TOPLEFT", iconFrame, "TOPRIGHT", 4, 0)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    nameFS:SetMaxLines(1)
    row.nameFS = nameFS

    local manaFS = row:CreateFontString(nil, "OVERLAY")
    manaFS:SetPoint("BOTTOMLEFT", iconFrame, "BOTTOMRIGHT", 4, 0)
    manaFS:SetJustifyH("LEFT")
    manaFS:SetWordWrap(false)
    manaFS:SetMaxLines(1)
    row.manaFS = manaFS

    row:Hide()
    return row
end

AcquireRow = function(key)
    local pool = rowPools[key]
    local row = table.remove(pool)
    if not row then
        row = CreateHealerRow(containers[key])
    end
    row:SetParent(containers[key])
    activeRows[key][#activeRows[key] + 1] = row
    return row
end

ReleaseAllRows = function(key)
    local active = activeRows[key]
    local pool = rowPools[key]
    for i = #active, 1, -1 do
        local row = active[i]
        row:Hide()
        row:ClearAllPoints()
        pool[#pool + 1] = row
        active[i] = nil
    end
end

-- Applies every settings-driven per-row visual: font, and icon/row size (so
-- already-created pooled/active rows pick up a live icon-size-slider change
-- instead of staying stuck at their creation-time size).
-- textColumnWidth: the dynamically-measured pixel width needed for the
-- name/mana text at the current font/size (see ComputeTextColumnWidth) --
-- callers compute this ONCE per container refresh so every row in that
-- container shares the same width (uniform column, no per-row jitter).
ApplyRowStyle = function(row, textColumnWidth)
    local cfg = DB()
    if not cfg or not row then return end
    local fontPath = GetFontPath(cfg.fontFace or "__global")
    row.nameFS:SetFont(fontPath, cfg.fontSize or 12, "OUTLINE")
    row.manaFS:SetFont(fontPath, cfg.fontSize or 12, "OUTLINE")

    local iconSize = GetIconSize()
    local showIcon = IsIconShown()
    row.iconFrame:SetSize(iconSize, iconSize)
    row.iconFrame:SetShown(showIcon)

    -- Name's top matches the icon's top, mana's bottom matches the icon's
    -- bottom -- dynamic against whatever the icon size slider is set to,
    -- no fixed offset to keep in sync. Icon hidden: same TOP/BOTTOM pairing
    -- but against the row's own edges (row height still equals iconSize),
    -- reclaiming the icon+gap width.
    row.nameFS:ClearAllPoints()
    row.manaFS:ClearAllPoints()
    if showIcon then
        row.nameFS:SetPoint("TOPLEFT", row.iconFrame, "TOPRIGHT", 4, 0)
        row.manaFS:SetPoint("BOTTOMLEFT", row.iconFrame, "BOTTOMRIGHT", 4, 0)
    else
        row.nameFS:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        row.manaFS:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    end

    row:SetSize(GetRowWidth(textColumnWidth), iconSize)
end

UpdateManaDisplay = function(row, unit, connected)
    if connected then
        row.icon:SetVertexColor(1, 1, 1)
        local pct = GetManaPercent(unit)
        row.manaFS:SetFormattedText("%.0f%%", pct)
        row.manaFS:SetTextColor(GetManaTextColor(pct))
    else
        row.icon:SetVertexColor(0.4, 0.4, 0.4)
        row.manaFS:SetText("OFFLINE")
        row.manaFS:SetTextColor(0.5, 0.5, 0.5, 1)
    end
end

-------------------------------------------------------------------------------
--  Healer detection
-------------------------------------------------------------------------------
AddHealer = function(key, unit, frameIndex)
    local healerName = UnitName(unit)
    if issecretvalue and issecretvalue(healerName) then healerName = "Healer" end
    local _, class = UnitClass(unit)
    local guid = UnitGUID(unit)
    local r, g, b = GetClassColor(class)

    currentHealers[key][#currentHealers[key] + 1] = {
        unit = unit,
        guid = guid,
        name = healerName,
        class = class,
        colorR = r, colorG = g, colorB = b,
        connected = UnitIsConnected(unit),
        frameIndex = frameIndex,
        specID = specCache[guid],
    }
end

GetHealerByGUID = function(guid)
    for _, def in ipairs(CONTAINER_DEFS) do
        for _, healer in ipairs(currentHealers[def.key]) do
            if healer.guid == guid then return def.key, healer end
        end
    end
end

FindHealerByUnit = function(unit)
    for _, def in ipairs(CONTAINER_DEFS) do
        for _, healer in ipairs(currentHealers[def.key]) do
            if healer.unit == unit then return def.key, healer end
        end
    end
end

-------------------------------------------------------------------------------
--  Inspect queue -- real spec icon via NotifyInspect/GetInspectSpecialization,
--  serialized one-at-a-time with a 2s timeout (standard, non-secure API; the
--  queue just avoids spamming NotifyInspect for several healers at once).
-------------------------------------------------------------------------------
QueueInspect = function(healer)
    if not healer or not healer.unit or not healer.guid then return end
    for _, queued in ipairs(inspectQueue) do
        if queued.guid == healer.guid then return end
    end
    inspectQueue[#inspectQueue + 1] = healer
    ProcessInspectQueue()
end

ProcessInspectQueue = function()
    if currentInspect then return end
    if #inspectQueue == 0 then return end

    local healer = inspectQueue[1]
    if not healer or not UnitExists(healer.unit) or not CanInspect(healer.unit) then
        table.remove(inspectQueue, 1)
        C_Timer.After(0.1, ProcessInspectQueue)
        return
    end

    currentInspect = healer.guid
    NotifyInspect(healer.unit)

    C_Timer.After(2, function()
        if currentInspect == healer.guid then
            currentInspect = nil
            ProcessInspectQueue()
        end
    end)
end

OnInspectReady = function(guid)
    if currentInspect ~= guid then return end
    currentInspect = nil

    for i, queued in ipairs(inspectQueue) do
        if queued.guid == guid then
            table.remove(inspectQueue, i)
            break
        end
    end

    local key, healer = GetHealerByGUID(guid)
    if not healer or not UnitExists(healer.unit) then
        C_Timer.After(INSPECT_DELAY, ProcessInspectQueue)
        return
    end

    local specID = GetInspectSpecialization(healer.unit)
    if specID and specID > 0 then
        specCache[guid] = specID
        healer.specID = specID
        RefreshHealerIcon(key, healer)
    end

    C_Timer.After(INSPECT_DELAY, ProcessInspectQueue)
end

ClearInspectQueue = function()
    wipe(inspectQueue)
    currentInspect = nil
end

-------------------------------------------------------------------------------
--  Per-unit refresh
-------------------------------------------------------------------------------
RefreshHealerIcon = function(key, healer)
    local row = activeRows[key] and activeRows[key][healer.frameIndex]
    if not row then return end
    local icon = healer.specID and select(4, GetSpecializationInfoByID(healer.specID))
    row.icon:SetTexture(icon or FALLBACK_ICON)
end

RefreshHealerRow = function(unit)
    local key, healer = FindHealerByUnit(unit)
    if not key or not healer then return end
    local row = activeRows[key] and activeRows[key][healer.frameIndex]
    if not row then return end
    local connected = UnitIsConnected(unit)
    healer.connected = connected
    UpdateManaDisplay(row, unit, connected)
end

-------------------------------------------------------------------------------
--  Rebuild a container's rows from currentHealers[key]
-------------------------------------------------------------------------------
RefreshContainer = function(key)
    local container = containers[key]
    if not container then return end

    ReleaseAllRows(key)

    local healers = currentHealers[key]
    if #healers == 0 then
        container:Hide()
        UpdateContainerSize(key, ComputeTextColumnWidth({}))
        return
    end

    local names = {}
    for _, healer in ipairs(healers) do
        names[#names + 1] = TruncateHealerName(healer.name)
    end
    local textW = ComputeTextColumnWidth(names)

    for _, healer in ipairs(healers) do
        local row = AcquireRow(key)
        ApplyRowStyle(row, textW)

        local icon
        if healer.specID then
            icon = select(4, GetSpecializationInfoByID(healer.specID))
        else
            QueueInspect(healer)
        end
        row.icon:SetTexture(icon or FALLBACK_ICON)
        row.icon:SetVertexColor(1, 1, 1)

        row.nameFS:SetText(TruncateHealerName(healer.name))
        row.nameFS:SetTextColor(healer.colorR, healer.colorG, healer.colorB, 1)

        UpdateManaDisplay(row, healer.unit, healer.connected)
        row:Show()
    end

    UpdateContainerSize(key, textW)
    LayoutRows(key, textW)
    container:Show()
end

-- Re-filters the shared runtime frame's per-unit event registrations to
-- exactly the currently-tracked healer units. UNIT_POWER_UPDATE fires on
-- normal power ticks; UNIT_POWER_FREQUENT fires repeatedly during fast
-- regen/decay (e.g. Evocation, mana potions, burst mana drain); UNIT_CONNECTION
-- fires on connect/disconnect. All three are verified-real registerable
-- events (unlike the earlier, wrong "UNIT_POWER_FREQUENT_UPDATE" guess).
local TRACK_EVENTS = { "UNIT_POWER_UPDATE", "UNIT_POWER_FREQUENT", "UNIT_CONNECTION" }

SyncUnitEvents = function()
    if not runtimeFrame then return end
    for _, ev in ipairs(TRACK_EVENTS) do
        runtimeFrame:UnregisterEvent(ev)
    end
    for _, def in ipairs(CONTAINER_DEFS) do
        for _, healer in ipairs(currentHealers[def.key]) do
            for _, ev in ipairs(TRACK_EVENTS) do
                runtimeFrame:RegisterUnitEvent(ev, healer.unit)
            end
        end
    end
end

-------------------------------------------------------------------------------
--  Group roster scan
-------------------------------------------------------------------------------
FindHealers = function()
    local cfg = DB()
    if not cfg or not cfg.enabled then return end
    if unlockStubActive then return end

    wipe(currentHealers.party)
    wipe(currentHealers.raid)

    if IsInGroup() then
        if IsInRaid() then
            if cfg.showInRaid then
                local numMembers = GetNumGroupMembers()
                local count = 0
                for i = 1, numMembers do
                    local unit = "raid" .. i
                    if UnitExists(unit) and UnitGroupRolesAssigned(unit) == "HEALER" then
                        count = count + 1
                        AddHealer("raid", unit, count)
                    end
                end
            end
        elseif cfg.showInParty then
            local count = 0
            for i = 1, 4 do
                local unit = "party" .. i
                if UnitExists(unit) and UnitGroupRolesAssigned(unit) == "HEALER" then
                    count = count + 1
                    AddHealer("party", unit, count)
                end
            end
        end
    end

    RefreshContainer("party")
    RefreshContainer("raid")
    SyncUnitEvents()
end

OnSpecChanged = function(unit)
    if not unit then return end
    local _, healer = FindHealerByUnit(unit)
    if not healer then return end
    if healer.guid then specCache[healer.guid] = nil end
    healer.specID = nil
    QueueInspect(healer)
end

-------------------------------------------------------------------------------
--  Unlock Mode stub -- Unlock Mode is for moving/sizing frames, not viewing
--  their content, so this shows the container EMPTY (no icon/name/mana rows)
--  at a correctly-sized, correctly-positioned stub. It exists because the
--  real container is normally only shown when actual healers are found
--  (RefreshContainer), so opening Unlock Mode while solo or without a live
--  healer would otherwise leave nothing to see or drag. The stub's size uses
--  the current font/icon-size/max-name-length settings (via
--  ComputeTextColumnWidth) so it still reflects what real content would
--  occupy, without fabricating any actual row content to show.
-------------------------------------------------------------------------------
ShowUnlockStub = function(key)
    local cfg = DB()
    local container = EnsureContainer(key)
    if not cfg or not container then return end

    ReleaseAllRows(key)
    wipe(currentHealers[key])

    local textW = ComputeTextColumnWidth({})
    UpdateContainerSize(key, textW)
    ApplyPosition(key)
    container:Show()
end

ShowUnlockStubs = function()
    unlockStubActive = true
    ShowUnlockStub("party")
    ShowUnlockStub("raid")
end

HideAllFrames = function()
    for _, def in ipairs(CONTAINER_DEFS) do
        wipe(currentHealers[def.key])
        ReleaseAllRows(def.key)
        if containers[def.key] then containers[def.key]:Hide() end
    end
    ClearInspectQueue()
end

-------------------------------------------------------------------------------
--  Unlock mode registration (mirrors EllesmereUIVoidlol_CombatText.lua)
-------------------------------------------------------------------------------
TryHookUnlockFrame = function()
    if unlockHooksInstalled then return end
    local unlockFrame = _G.EllesmereUnlockMode
    if not unlockFrame then return end

    unlockHooksInstalled = true
    unlockFrame:HookScript("OnShow", function()
        local cfg = DB()
        if not cfg or not cfg.enabled then return end
        ShowUnlockStubs()
    end)
    unlockFrame:HookScript("OnHide", function()
        unlockStubActive = false
        local cfg = DB()
        if cfg and cfg.enabled then
            FindHealers()
        else
            HideAllFrames()
        end
    end)
end

RegisterUnlock = function()
    if unlockRegistered then return end
    if not EllesmereUI or not EllesmereUI.RegisterUnlockElements or not EllesmereUI.MakeUnlockElement then return end
    local MK = EllesmereUI.MakeUnlockElement

    local elements = {}
    for i, def in ipairs(CONTAINER_DEFS) do
        elements[#elements + 1] = MK({
            key            = def.unlockKey,
            label          = def.label,
            group          = "Voidlol",
            order          = 200 + i,
            noResize       = true,
            noAnchorTarget = true, -- row count changes dynamically with the live healer list
            getFrame       = function() return EnsureContainer(def.key) end,
            getSize        = function()
                local c = containers[def.key]
                if c then return c:GetWidth(), c:GetHeight() end
                return GetRowWidth(0), GetIconSize()
            end,
            isHidden       = function()
                local cfg = DB()
                if not cfg or not cfg.enabled then return true end
                if def.key == "party" then return not cfg.showInParty end
                return not cfg.showInRaid
            end,
            savePos        = function()
                local cfg = DB()
                local f = containers[def.key]
                if not cfg or not f or not f:GetCenter() then return end
                local cx, cy = f:GetCenter()
                local upX, upY = UIParent:GetCenter()
                local fes = f:GetEffectiveScale() or 1
                local ues = UIParent:GetEffectiveScale() or 1
                local ratio = fes / ues
                cfg[GetPosKey(def.key)] = { centerX = cx * ratio - upX, centerY = cy * ratio - upY }
            end,
            loadPos        = function()
                local cfg = DB()
                return cfg and cfg[GetPosKey(def.key)]
            end,
            clearPos       = function()
                local cfg = DB()
                if cfg then cfg[GetPosKey(def.key)] = nil end
            end,
            applyPos       = function() ApplyPosition(def.key) end,
        })
    end
    EllesmereUI:RegisterUnlockElements(elements, "EllesmereUIVoidlol")
    unlockRegistered = true
    TryHookUnlockFrame()
end

-------------------------------------------------------------------------------
--  Runtime event frame -- created/registered ONLY while enabled (zero cost
--  unless the module is opted into).
-------------------------------------------------------------------------------
local function EnsureRuntimeFrame()
    if runtimeFrame then return runtimeFrame end
    runtimeFrame = CreateFrame("Frame")
    runtimeFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
            FindHealers()
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            OnSpecChanged(...)
        elseif event == "INSPECT_READY" then
            OnInspectReady(...)
        elseif event == "UNIT_CONNECTION" then
            RefreshHealerRow((...))
        elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" then
            local unit, powerType = ...
            if powerType == "MANA" then
                RefreshHealerRow(unit)
            end
        end
    end)
    return runtimeFrame
end

EnableRuntime = function()
    local frame = EnsureRuntimeFrame()
    frame:RegisterEvent("GROUP_ROSTER_UPDATE")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    frame:RegisterEvent("INSPECT_READY")
    SyncUnitEvents()
end

DisableRuntime = function()
    if runtimeFrame then runtimeFrame:UnregisterAllEvents() end
end

-------------------------------------------------------------------------------
--  Apply (called on settings change / login)
-------------------------------------------------------------------------------
ApplyAll = function()
    local cfg = DB()
    if not cfg or not cfg.enabled then
        DisableRuntime()
        HideAllFrames()
        unlockStubActive = false
        return
    end

    EnsureContainer("party")
    EnsureContainer("raid")
    ApplyPosition("party")
    ApplyPosition("raid")

    for _, def in ipairs(CONTAINER_DEFS) do
        local names = {}
        for _, healer in ipairs(currentHealers[def.key]) do
            names[#names + 1] = TruncateHealerName(healer.name)
        end
        local textW = ComputeTextColumnWidth(names)
        for _, row in ipairs(activeRows[def.key]) do ApplyRowStyle(row, textW) end
        for _, row in ipairs(rowPools[def.key]) do ApplyRowStyle(row, textW) end
    end

    EnableRuntime()
    RegisterUnlock()
    TryHookUnlockFrame()

    if EllesmereUI.IsUnlockModeActive and EllesmereUI.IsUnlockModeActive() then
        ShowUnlockStubs()
    else
        unlockStubActive = false
        FindHealers()
    end
end
EVL.ApplyHealerMana = ApplyAll

-------------------------------------------------------------------------------
--  Options-page preview row API -- a standalone row, independent of the live
--  containers/Enabled/Unlock Mode, that EUI_Voidlol_Options.lua builds once
--  and re-styles on every settings change. This is what makes the Healer Mana
--  options page always show a live sample, regardless of whether the feature
--  is enabled or Unlock Mode is open.
-------------------------------------------------------------------------------
function EVL.HealerMana_CreatePreviewRow(parent)
    return CreateHealerRow(parent)
end

-- Picks a random spec/name from the same pools the Unlock Mode preview uses
-- (PREVIEW_SPECS/PREVIEW_NAMES), so the options-page preview varies its icon
-- and name too, not just its mana%, without duplicating those lists.
function EVL.HealerMana_GetRandomPreviewSample()
    local specID = PREVIEW_SPECS[math.random(1, #PREVIEW_SPECS)]
    local name = PREVIEW_NAMES[math.random(1, #PREVIEW_NAMES)]
    return specID, name
end

function EVL.HealerMana_StylePreviewRow(row, specID, fakeName, manaPct)
    if not row then return end
    local displayName = TruncateHealerName(fakeName)
    ApplyRowStyle(row, ComputeTextColumnWidth({ displayName }))

    local _, _, _, icon, _, class = GetSpecializationInfoByID(specID)
    local r, g, b = GetClassColor(class)
    row.icon:SetTexture(icon or FALLBACK_ICON)
    row.icon:SetVertexColor(1, 1, 1)

    row.nameFS:SetText(displayName)
    row.nameFS:SetTextColor(r, g, b, 1)

    row.manaFS:SetFormattedText("%d%%", manaPct)
    row.manaFS:SetTextColor(GetManaTextColor(manaPct))

    row:Show()
end

-------------------------------------------------------------------------------
--  Bootstrap
-------------------------------------------------------------------------------
function EVL.InitHealerMana()
    ApplyAll()
end
