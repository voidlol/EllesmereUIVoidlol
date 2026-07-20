-------------------------------------------------------------------------------
--  EllesmereUIVoidlol_HealerMana.lua
--  Shows mana% (+ spec icon + name) for your group's/raid's healers. Two
--  independent containers -- "Healer Mana (Party)" and "Healer Mana (Raid)"
--  -- each separately positionable via EllesmereUI Unlock Mode, mirroring
--  EllesmereUIVoidlol_CombatText.lua's two-frame pattern. Every visual
--  setting (icon, text, sizes, colors, one-line mode) is independent per
--  frame -- only the master Enabled switch is shared.
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
--     options page always shows two standalone sample groups -- Party (1
--     row) and Raid (4 rows) -- via EVL.HealerMana_EnsurePreviewGroup/
--     RefreshPreviewGroup, called from EUI_Voidlol_Options.lua, regardless
--     of Enabled/Unlock Mode, so settings changes are visible immediately
--     for BOTH frames at once without needing to enable the feature.
--   - Spec icon accuracy uses the same queued NotifyInspect/GetInspectSpecialization
--     flow every inspect-based addon uses (not secure/tainted, just throttled).
--   - The configurable mana color applies to the mana% text only -- names
--     stay class-colored (matches how cast-target text is handled elsewhere).
--   - Icon hidden: One Line Mode puts name+mana side by side ("Healername
--     99%"); off (default) stacks mana directly under the name. Neither is
--     tied to the icon's height/position (there's no icon) -- row height is
--     computed from the frame's own font size instead.
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
-- Used only by the options-page standalone preview groups -- Unlock Mode
-- itself shows an empty stub, no sample spec/name/mana content.
local PREVIEW_SPECS = { 105, 270, 65, 256, 257, 264, 1468 } -- Resto Druid, Mistweaver, Holy Pala, Disc, Holy Priest, Resto Sham, Preservation
-- Mix of short and long fake names -- the long ones visibly demonstrate the
-- name-length-limit setting in the preview, not just theoretically; the
-- short ones show what a healer with an ordinary name actually looks like.
local PREVIEW_NAMES = {
    "Zar", "Nyx", "Kael", "Lira", "Thorne", "Vexis", "Draven", "Sable",
    "Ashwing", "Duskryn",
    "Thunderstrikeus", "Moonshadowblade", "Emberheartsong", "Frostwhisperus",
    "Stormbringerae", "Shadowweaveris", "Ironvowborn", "Starfallenus",
    "Windrunnerae", "Bloodmoonrise",
}
local INSPECT_DELAY = 0.05

local DEFAULT_ICON_SIZE = 24
local ICON_GAP          = 4
local ROW_SPACING       = 3
local TEXT_GAP          = 4  -- One Line Mode: gap between name and mana%
local STACK_GAP         = 2  -- Icon off, stacked: gap between name and mana lines

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
-- Master table: { enabled, party = {...}, raid = {...} }.
local function DB()
    local d = EVL.DB and EVL.DB()
    return d and d.healerMana
end

-- Per-frame settings table ("party" | "raid").
local function FrameDB(key)
    local hm = DB()
    return hm and hm[key]
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
-- pct just gets a flat default (#008CFF) unless the user picked a custom color.
local DEFAULT_MANA_COLOR = { 0x00 / 255, 0x8C / 255, 0xFF / 255 }

local function GetManaTextColor(key, pct)
    local cfg = FrameDB(key)
    if cfg and cfg.useCustomManaColor then
        return cfg.manaColorR or 1, cfg.manaColorG or 1, cfg.manaColorB or 1, 1
    end
    return DEFAULT_MANA_COLOR[1], DEFAULT_MANA_COLOR[2], DEFAULT_MANA_COLOR[3], 1
end

local function GetIconSize(key)
    local cfg = FrameDB(key)
    local size = cfg and cfg.iconSize
    if type(size) ~= "number" then return DEFAULT_ICON_SIZE end
    return size
end

local function IsIconShown(key)
    local cfg = FrameDB(key)
    return not cfg or cfg.showIcon ~= false
end

local function IsOneLineMode(key)
    local cfg = FrameDB(key)
    return cfg and cfg.oneLineMode == true
end

-- Row height only cares about icon size while the icon is actually shown;
-- once it's off, nothing should key off it anymore (see file header).
local function TextLineHeight(key)
    local cfg = FrameDB(key)
    local fontSize = (cfg and cfg.fontSize) or 12
    return fontSize + 4
end

local function GetRowHeight(key)
    if IsIconShown(key) then return GetIconSize(key) end
    local lineH = TextLineHeight(key)
    if IsOneLineMode(key) then return lineH end
    return lineH * 2 + STACK_GAP
end

-- #name/string.sub count/cut BYTES, not characters -- every non-Latin letter
-- (Cyrillic, etc) is a multi-byte UTF-8 sequence, so a byte-based cut both
-- undercounts the visible length and can slice a character in half. Iterate
-- by UTF-8 sequence instead: one leading byte (ASCII, or a 0xC2-0xF4 lead
-- byte) followed by its continuation bytes (0x80-0xBF).
local function Utf8Iter(str) return (str or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") end

local function Utf8Len(str)
    local len = 0
    for _ in Utf8Iter(str) do len = len + 1 end
    return len
end

local function Utf8Sub(str, maxLen)
    local out, n = {}, 0
    for char in Utf8Iter(str) do
        n = n + 1
        if n > maxLen then break end
        out[n] = char
    end
    return table.concat(out)
end

-- maxLen <= 0 (or unset) means unlimited, matching the options slider's "0 = Unlimited".
local function TruncateHealerName(key, name)
    if not name then return "" end
    local cfg = FrameDB(key)
    local maxLen = cfg and cfg.nameMaxLength
    if not maxLen or maxLen <= 0 or Utf8Len(name) <= maxLen then return name end
    return Utf8Sub(name, maxLen)
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
--
-- Icon off + One Line Mode: name and mana sit side by side, so the row needs
-- their SUM (+ gap), not the max of the two (the stacked/icon-on layouts,
-- where they share one column).
local function ComputeTextColumnWidth(key, names)
    local cfg = FrameDB(key)
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

    if not IsIconShown(key) and IsOneLineMode(key) then
        return nameW + TEXT_GAP + manaW
    end
    return math.max(nameW, manaW)
end

local function GetRowWidth(key, textColumnWidth)
    if not IsIconShown(key) then return textColumnWidth or 0 end
    return GetIconSize(key) + ICON_GAP + (textColumnWidth or 0)
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
    frame:SetSize(GetRowWidth(key, 0), GetRowHeight(key)) -- placeholder; corrected by the first RefreshContainer/ShowUnlockStub
    frame:Hide()
    containers[key] = frame
    return frame
end

-- Anchored by TOPLEFT (not CENTER): with a CENTER anchor, SetSize during
-- RefreshContainer (row count changes) would expand the container equally in
-- both directions around the fixed center point -- e.g. a VERTICAL frame
-- growing from 2 to 3 rows would shift row 1 upward instead of just adding
-- row 3 below, and HORIZONTAL likewise crept row 1 left. TOPLEFT keeps that
-- corner pinned, so VERTICAL only ever extends downward and HORIZONTAL only
-- ever extends rightward, matching the per-row math in LayoutRows below.
ApplyPosition = function(key)
    local cfg = FrameDB(key)
    local container = containers[key]
    if not cfg or not container then return end

    local fes = container:GetEffectiveScale() or 1
    local ues = UIParent:GetEffectiveScale() or 1
    local ratio = fes / ues
    local w = (container:GetWidth() or 0) * ratio
    local h = (container:GetHeight() or 0) * ratio

    local pos = cfg.pos
    -- One-time migration from the old CENTER-anchored format: convert to an
    -- equivalent top-left using the container's current size so existing
    -- users' frames don't jump on update.
    if pos and pos.centerX ~= nil and pos.left == nil then
        pos = { left = pos.centerX - w / 2, top = pos.centerY + h / 2 }
        cfg.pos = pos
    end

    container:ClearAllPoints()
    if pos then
        container:SetPoint("TOPLEFT", UIParent, "CENTER", pos.left, pos.top)
    else
        local defCenterX = key == "party" and -250 or 250
        container:SetPoint("TOPLEFT", UIParent, "CENTER", defCenterX - w / 2, h / 2)
    end
end

-- Growth direction: party always stacks vertically; raid respects the
-- configurable dropdown (a raid-only setting, so it lives under raid's own
-- settings table). Only raid exposes the option (per spec).
LayoutRows = function(key, textColumnWidth)
    local container = containers[key]
    local rows = activeRows[key]
    if not container or not rows then return end

    local raidCfg = FrameDB("raid")
    local direction = (key == "raid") and (raidCfg and raidCfg.raidGrowDirection or "VERTICAL") or "VERTICAL"
    local rowH = GetRowHeight(key)
    local rowWidth = GetRowWidth(key, textColumnWidth)

    for i, row in ipairs(rows) do
        row:ClearAllPoints()
        if direction == "HORIZONTAL" then
            row:SetPoint("TOPLEFT", container, "TOPLEFT", (i - 1) * (rowWidth + ROW_SPACING), 0)
        else
            row:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -((i - 1) * (rowH + ROW_SPACING)))
        end
    end
end

UpdateContainerSize = function(key, textColumnWidth)
    local container = containers[key]
    if not container then return end

    local rowH = GetRowHeight(key)
    local rowWidth = GetRowWidth(key, textColumnWidth)

    local count = #activeRows[key]
    if count == 0 then
        container:SetSize(rowWidth, rowH)
        return
    end

    local raidCfg = FrameDB("raid")
    local direction = (key == "raid") and (raidCfg and raidCfg.raidGrowDirection or "VERTICAL") or "VERTICAL"
    if direction == "HORIZONTAL" then
        container:SetSize((rowWidth * count) + (ROW_SPACING * (count - 1)), rowH)
    else
        container:SetSize(rowWidth, (rowH * count) + (ROW_SPACING * (count - 1)))
    end
end

-------------------------------------------------------------------------------
--  Row frames (icon + name + mana%), pooled per container
-------------------------------------------------------------------------------
CreateHealerRow = function(key, container)
    local row = CreateFrame("Frame", nil, container)
    row:SetSize(GetRowWidth(key, 0), GetRowHeight(key)) -- placeholder; ApplyRowStyle corrects it immediately after acquire

    local iconFrame = CreateFrame("Frame", nil, row)
    iconFrame:SetSize(GetIconSize(key), GetIconSize(key))
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
        row = CreateHealerRow(key, containers[key])
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

-- Applies every settings-driven per-row visual: font, icon show/size, and the
-- name/mana layout for this frame's (party/raid) OWN settings.
-- textColumnWidth: the dynamically-measured pixel width needed for the
-- name/mana text at the current font/size (see ComputeTextColumnWidth) --
-- callers compute this ONCE per container refresh so every row in that
-- container shares the same width (uniform column, no per-row jitter).
ApplyRowStyle = function(key, row, textColumnWidth)
    local cfg = FrameDB(key)
    if not cfg or not row then return end
    local fontPath = GetFontPath(cfg.fontFace or "__global")
    row.nameFS:SetFont(fontPath, cfg.fontSize or 12, "OUTLINE")
    row.manaFS:SetFont(fontPath, cfg.fontSize or 12, "OUTLINE")

    local iconSize = GetIconSize(key)
    local showIcon = IsIconShown(key)
    local oneLine = IsOneLineMode(key)
    row.iconFrame:SetSize(iconSize, iconSize)
    row.iconFrame:SetShown(showIcon)

    row.nameFS:ClearAllPoints()
    row.manaFS:ClearAllPoints()
    if showIcon then
        -- Name's top matches the icon's top, mana's bottom matches the
        -- icon's bottom -- dynamic against whatever the icon size slider is
        -- set to, no fixed offset to keep in sync.
        row.nameFS:SetPoint("TOPLEFT", row.iconFrame, "TOPRIGHT", 4, 0)
        row.manaFS:SetPoint("BOTTOMLEFT", row.iconFrame, "BOTTOMRIGHT", 4, 0)
    elseif oneLine then
        -- No icon, single line: name then mana, side by side.
        row.nameFS:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.manaFS:SetPoint("LEFT", row.nameFS, "RIGHT", TEXT_GAP, 0)
    else
        -- No icon, stacked (default): mana anchored directly under the name
        -- -- tied to the name text itself, not to the icon that's no longer
        -- there and not to the row's raw edges.
        row.nameFS:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        row.manaFS:SetPoint("TOPLEFT", row.nameFS, "BOTTOMLEFT", 0, -STACK_GAP)
    end

    row:SetSize(GetRowWidth(key, textColumnWidth), GetRowHeight(key))
end

UpdateManaDisplay = function(key, row, unit, connected)
    if connected then
        row.icon:SetVertexColor(1, 1, 1)
        local pct = GetManaPercent(unit)
        row.manaFS:SetFormattedText("%.0f%%", pct)
        row.manaFS:SetTextColor(GetManaTextColor(key, pct))
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
    UpdateManaDisplay(key, row, unit, connected)
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
        UpdateContainerSize(key, ComputeTextColumnWidth(key, {}))
        return
    end

    local names = {}
    for _, healer in ipairs(healers) do
        names[#names + 1] = TruncateHealerName(key, healer.name)
    end
    local textW = ComputeTextColumnWidth(key, names)

    for _, healer in ipairs(healers) do
        local row = AcquireRow(key)
        ApplyRowStyle(key, row, textW)

        local icon
        if healer.specID then
            icon = select(4, GetSpecializationInfoByID(healer.specID))
        else
            QueueInspect(healer)
        end
        row.icon:SetTexture(icon or FALLBACK_ICON)
        row.icon:SetVertexColor(1, 1, 1)

        row.nameFS:SetText(TruncateHealerName(key, healer.name))
        row.nameFS:SetTextColor(healer.colorR, healer.colorG, healer.colorB, 1)

        UpdateManaDisplay(key, row, healer.unit, healer.connected)
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
    local master = DB()
    if not master or not master.enabled then return end
    if unlockStubActive then return end

    wipe(currentHealers.party)
    wipe(currentHealers.raid)

    if IsInGroup() then
        if IsInRaid() then
            local raidCfg = FrameDB("raid")
            if raidCfg and raidCfg.enabled then
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
        else
            local partyCfg = FrameDB("party")
            if partyCfg and partyCfg.enabled then
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
--  this frame's current font/icon-size/max-name-length settings (via
--  ComputeTextColumnWidth) so it still reflects what real content would
--  occupy, without fabricating any actual row content to show.
-------------------------------------------------------------------------------
ShowUnlockStub = function(key)
    local cfg = FrameDB(key)
    local container = EnsureContainer(key)
    if not cfg or not container then return end

    ReleaseAllRows(key)
    wipe(currentHealers[key])

    local textW = ComputeTextColumnWidth(key, {})
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
        local master = DB()
        if not master or not master.enabled then return end
        ShowUnlockStubs()
    end)
    unlockFrame:HookScript("OnHide", function()
        unlockStubActive = false
        local master = DB()
        if master and master.enabled then
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
                return GetRowWidth(def.key, 0), GetRowHeight(def.key)
            end,
            isHidden       = function()
                local master = DB()
                if not master or not master.enabled then return true end
                local fcfg = FrameDB(def.key)
                return not (fcfg and fcfg.enabled)
            end,
            savePos        = function()
                local fcfg = FrameDB(def.key)
                local f = containers[def.key]
                if not fcfg or not f or not f:GetLeft() or not f:GetTop() then return end
                local left, top = f:GetLeft(), f:GetTop()
                local upX, upY = UIParent:GetCenter()
                local fes = f:GetEffectiveScale() or 1
                local ues = UIParent:GetEffectiveScale() or 1
                local ratio = fes / ues
                fcfg.pos = { left = left * ratio - upX, top = top * ratio - upY }
            end,
            loadPos        = function()
                local fcfg = FrameDB(def.key)
                return fcfg and fcfg.pos
            end,
            clearPos       = function()
                local fcfg = FrameDB(def.key)
                if fcfg then fcfg.pos = nil end
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
    local master = DB()
    if not master or not master.enabled then
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
            names[#names + 1] = TruncateHealerName(def.key, healer.name)
        end
        local textW = ComputeTextColumnWidth(def.key, names)
        for _, row in ipairs(activeRows[def.key]) do ApplyRowStyle(def.key, row, textW) end
        for _, row in ipairs(rowPools[def.key]) do ApplyRowStyle(def.key, row, textW) end
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
--  Options-page preview API -- builds/styles a standalone group of `count`
--  sample rows for `key` ("party" | "raid"), independent of the live
--  containers/Enabled/Unlock Mode, laid out the same way
--  RefreshContainer/LayoutRows would (respecting that frame's own icon/font/
--  one-line/raid-grow-direction settings). EUI_Voidlol_Options.lua calls this
--  once for "party" (count 1) and once for "raid" (count 4) so the options
--  page always shows BOTH frames live, side by side, regardless of whether
--  the feature is enabled or which group you're actually in.
-------------------------------------------------------------------------------
local previewGroups = {} -- key -> { frame, rows = {row1, row2, ...} }

function EVL.HealerMana_EnsurePreviewGroup(key, parent, count)
    local g = previewGroups[key]
    if not g then
        g = { frame = CreateFrame("Frame", nil, parent), rows = {} }
        previewGroups[key] = g
    else
        g.frame:SetParent(parent)
    end
    for i = 1, count do
        if not g.rows[i] then
            g.rows[i] = CreateHealerRow(key, g.frame)
        end
    end
    for i = count + 1, #g.rows do
        if g.rows[i] then g.rows[i]:Hide() end
    end
    return g.frame
end

function EVL.HealerMana_RefreshPreviewGroup(key, count)
    local g = previewGroups[key]
    if not g then return 0, 0 end

    local samples, names = {}, {}
    for i = 1, count do
        local specID = PREVIEW_SPECS[math.random(1, #PREVIEW_SPECS)]
        local name = PREVIEW_NAMES[math.random(1, #PREVIEW_NAMES)]
        local displayName = TruncateHealerName(key, name)
        samples[i] = { specID = specID, pct = math.random(1, 100), displayName = displayName }
        names[i] = displayName
    end
    local textW = ComputeTextColumnWidth(key, names)

    for i = 1, count do
        local row = g.rows[i]
        ApplyRowStyle(key, row, textW)

        local s = samples[i]
        local _, _, _, icon, _, class = GetSpecializationInfoByID(s.specID)
        local r, gc, b = GetClassColor(class)
        row.icon:SetTexture(icon or FALLBACK_ICON)
        row.icon:SetVertexColor(1, 1, 1)

        row.nameFS:SetText(s.displayName)
        row.nameFS:SetTextColor(r, gc, b, 1)

        row.manaFS:SetFormattedText("%d%%", s.pct)
        row.manaFS:SetTextColor(GetManaTextColor(key, s.pct))

        row:Show()
    end

    local rowH = GetRowHeight(key)
    local rowW = GetRowWidth(key, textW)
    local raidCfg = FrameDB("raid")
    local direction = (key == "raid") and (raidCfg and raidCfg.raidGrowDirection or "VERTICAL") or "VERTICAL"

    for i = 1, count do
        local row = g.rows[i]
        row:ClearAllPoints()
        if direction == "HORIZONTAL" then
            row:SetPoint("TOPLEFT", g.frame, "TOPLEFT", (i - 1) * (rowW + ROW_SPACING), 0)
        else
            row:SetPoint("TOPLEFT", g.frame, "TOPLEFT", 0, -((i - 1) * (rowH + ROW_SPACING)))
        end
    end

    local totalW, totalH
    if direction == "HORIZONTAL" then
        totalW = (rowW * count) + (ROW_SPACING * (count - 1))
        totalH = rowH
    else
        totalW = rowW
        totalH = (rowH * count) + (ROW_SPACING * (count - 1))
    end
    g.frame:SetSize(math.max(1, totalW), math.max(1, totalH))
    return totalW, totalH
end

-------------------------------------------------------------------------------
--  Bootstrap
-------------------------------------------------------------------------------
function EVL.InitHealerMana()
    ApplyAll()
end
