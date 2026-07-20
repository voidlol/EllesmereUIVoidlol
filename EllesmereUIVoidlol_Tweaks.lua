-------------------------------------------------------------------------------
--  EllesmereUIVoidlol_Tweaks.lua
--  Small hooks into other EllesmereUI modules, surfaced under the Tweaks
--  options tab (EUI_Voidlol_Options.lua).
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EVL = ns.EVL

local function DB()
    local d = EVL.DB and EVL.DB()
    return d and d.qol
end

-------------------------------------------------------------------------------
--  Spec-Based Rune Color (Death Knight)
--  EllesmereUI.GetClassResourceColor("Runes") is the single source the
--  "Class Resource Color" fill mode reads for DK rune pips -- both the live
--  render in EllesmereUIResourceBars and its own color-picker preview go
--  through it (see EllesmereUIResourceBars.lua ResolveSecondaryResourceColor
--  and EUI__General_Options.lua's Runes swatch). Normally it's one flat
--  color from the Class Resource Colors palette; this hooks it to return a
--  color keyed off the current spec (Blood/Frost/Unholy) instead, for every
--  key other than "Runes" (or non-DK) falling straight through untouched.
--  Only ever installed while actually playing a Death Knight, so the hook
--  body itself doesn't need to re-check class on every call.
-------------------------------------------------------------------------------
local RUNE_SPEC_COLORS = {
    [1] = { r = 0.77, g = 0.12, b = 0.23 }, -- Blood
    [2] = { r = 0.00, g = 0.82, b = 1.00 }, -- Frost
    [3] = { r = 0.42, g = 0.68, b = 0.20 }, -- Unholy
}

local cachedSpecIndex
local specWatcher

local function CacheSpecIndex()
    cachedSpecIndex = GetSpecialization()
end

local function EnsureSpecWatcher()
    if specWatcher then return end
    specWatcher = CreateFrame("Frame")
    specWatcher:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    specWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    specWatcher:SetScript("OnEvent", CacheSpecIndex)
    CacheSpecIndex()
end

local originalGetClassResourceColor

local function HookedGetClassResourceColor(key)
    if key == "Runes" then
        local sc = RUNE_SPEC_COLORS[cachedSpecIndex]
        if sc then return sc end
    end
    return originalGetClassResourceColor(key)
end

local function ApplyRunesSpecColor()
    local EUI = _G.EllesmereUI
    if not (EUI and EUI.GetClassResourceColor) then return end
    if not originalGetClassResourceColor then
        originalGetClassResourceColor = EUI.GetClassResourceColor
    end

    local _, class = UnitClass("player")
    local cfg = DB()
    if class == "DEATHKNIGHT" and cfg and cfg.runesSpecColored then
        EnsureSpecWatcher()
        EUI.GetClassResourceColor = HookedGetClassResourceColor
    else
        EUI.GetClassResourceColor = originalGetClassResourceColor
    end
end

-------------------------------------------------------------------------------
--  Debuff Border Color When Not Dispellable (Player & Target)
--  EllesmereUIUnitFrames' own dispel-type debuff border feature colors a
--  debuff icon's border by dispel type through each frame's
--  Debuffs.PostUpdateButton (a standard oUF Auras element hook) -- but for a
--  debuff that isn't dispellable (data.dispelName == nil) it restores a flat
--  black border. That coloring function is private to EllesmereUIUnitFrames'
--  own file-local namespace, so it can't be reached directly; instead this
--  wraps PostUpdateButton itself on the Player/Target Debuffs containers --
--  ordinary properties of frames we can reach by their known global names
--  (EllesmereUIUnitFrames_Player / _Target) -- calling the original first and
--  then recoloring the border to a custom color whenever it just went black
--  for that same "not dispellable" reason. Always safe to leave installed:
--  the recolor step itself no-ops unless the toggle below is on.
-------------------------------------------------------------------------------
local wrappedDebuffContainers = setmetatable({}, { __mode = "k" })

local function ApplyNotDispellableBorderColor(button, data)
    if not (data and data.dispelName == nil) then return end
    local border = button and button.Border
    if not border then return end
    local cfg = DB()
    if not (cfg and cfg.debuffNotDispellableColor) then return end
    local EUI = _G.EllesmereUI
    if not (EUI and EUI.PP and EUI.PP.SetBorderColor) then return end
    EUI.PP.SetBorderColor(border,
        cfg.debuffNotDispellableColorR or 0.5,
        cfg.debuffNotDispellableColorG or 0.5,
        cfg.debuffNotDispellableColorB or 0.5, 1)
end

local function HookDebuffContainer(debuffs)
    if not debuffs or wrappedDebuffContainers[debuffs] then return end
    wrappedDebuffContainers[debuffs] = true
    local orig = debuffs.PostUpdateButton
    debuffs.PostUpdateButton = function(element, button, unit, data)
        if orig then orig(element, button, unit, data) end
        ApplyNotDispellableBorderColor(button, data)
    end
end

local function HookDebuffContainers()
    local p = _G.EllesmereUIUnitFrames_Player
    local t = _G.EllesmereUIUnitFrames_Target
    if p then HookDebuffContainer(p.Debuffs) end
    if t then HookDebuffContainer(t.Debuffs) end
end

-- Defensive re-hook: if EllesmereUIUnitFrames ever rebuilds a Debuffs
-- container from scratch (settings change, profile swap), catch it via its
-- exposed global reload hook rather than assuming the frame object is
-- permanent for the whole session.
local reloadHooked = false
local function EnsureReloadFramesHook()
    if reloadHooked or not _G._EUF_ReloadFrames then return end
    reloadHooked = true
    local orig = _G._EUF_ReloadFrames
    _G._EUF_ReloadFrames = function(...)
        orig(...)
        HookDebuffContainers()
    end
end

local function ApplyDebuffNotDispellableColor()
    HookDebuffContainers()
    EnsureReloadFramesHook()
end

-------------------------------------------------------------------------------
--  Mirror CDM Cooldowns Visibility to CDM Bars
--  EllesmereUICooldownManager's CDM Bars page (the Essential/Utility/Buff
--  icon cooldown viewers) has a per-bar Visibility condition; its Tracking
--  Bars page (the separate buff-bar tracker) has no equivalent setting at
--  all -- always shown regardless of what Cooldowns is doing. Tracking Bars
--  frames are globally named (ECME_TBBWrap1, ECME_TBBWrap2, ... one per
--  configured bar, contiguous from 1).
--
--  Four dead ends before this: (1) CDM's visibility pass
--  (_CDMApplyVisibility) is a FILE-LOCAL function -- every internal call
--  site invokes that local directly, never through its _G._ECME_ApplyVisibility
--  alias, so wrapping the global never fires. (2) EssentialCooldownViewer:
--  SetAlpha looked like the right hook target, but that Blizzard viewer is
--  SHARED by every bar routed through it and only goes to 0 when ALL of them
--  are hidden -- a single bar (e.g. the default "cooldowns" bar) hiding on
--  its own condition hides that bar's OWN frame/icons, not the shared
--  viewer, so the viewer's alpha stayed 1 and never reflected that one
--  bar's state. _G._ECME_GetBarFrame("cooldowns") (CDM's own documented
--  "cross-addon frame lookup" accessor) fixed THAT -- it returns the exact
--  frame _CDMApplyVisibility sets to alpha 0/1 for that one bar. (3) Setting
--  the Tracking Bars frame's alpha directly still didn't stick: TBB's own
--  ~60fps tick (UpdateTrackedBuffBarTimers in EllesmereUICdmBuffBars.lua)
--  ends with a "smooth opacity lerp" pass that continuously drives every
--  bar's alpha back toward bar._opacityTarget (its configured opacity,
--  normally 1) -- a one-shot SetAlpha(0) reads as "off target" and gets
--  lerped straight back, and fighting it with our own repeating ticker just
--  produced a sawtooth flicker (ticker sets 0, lerp drags it back up before
--  the next tick). (4) This -- instead of touching alpha at all, override
--  Show() on each bar frame to refuse it while hidden; TBB's tick still
--  calls bar:Show() on every active-buff edge same as always, our override
--  just no-ops that call, so the frame stays truly Hidden (not merely
--  alpha-0) and nothing is fighting anything. No ticker needed: reacts once
--  per Cooldowns visibility change via a real hook on the Cooldowns bar's
--  own SetAlpha, and force-Hide()s anything already shown at that moment.
--
--  Known gap: a Tracking Bar CREATED while the mirror is already hiding
--  everything won't pick up the hook/flag until the next real Cooldowns
--  visibility transition (or a settings change that re-runs ApplyTweaks) --
--  CDM exposes no "TBB rebuilt" event to react to instead. Accepted
--  trade-off over adding a polling ticker back in.
--
--  Toggle discipline: while the toggle is off, this must not touch CDM or
--  Tracking Bars AT ALL -- not just "no visible effect". hookedTBBFrames
--  stores each touched frame's ORIGINAL Show so it can be put back exactly;
--  EnsureCDMVisibilityHook (hooksecurefunc, which can never be uninstalled)
--  is only ever called once the toggle is actually on, so a user who never
--  enables this never has CDM's SetAlpha hooked at all.
-------------------------------------------------------------------------------
local hookedTBBFrames = setmetatable({}, { __mode = "k" }) -- wrap -> original Show

local function EnsureTBBShowBlock(wrap)
    if hookedTBBFrames[wrap] then return end
    local origShow = wrap.Show
    hookedTBBFrames[wrap] = origShow
    wrap.Show = function(self, ...)
        if self._evlMirrorHide then return end
        return origShow(self, ...)
    end
end

-- Puts every touched Tracking Bars frame back exactly as CDM built it.
-- Any frame that's still legitimately supposed to be hidden (its tracked
-- buff isn't up) simply gets re-hidden by CDM's own tick on the next
-- active/inactive edge -- restoring here never forces a show.
local function RestoreAllTBBShowBlocks()
    for wrap, origShow in pairs(hookedTBBFrames) do
        wrap.Show = origShow
        wrap._evlMirrorHide = nil
        hookedTBBFrames[wrap] = nil
    end
end

local function GetCdmCooldownsBarFrame()
    return _G._ECME_GetBarFrame and _G._ECME_GetBarFrame("cooldowns")
end

-- Tracking Bars frames are contiguously numbered from 1 with no exposed
-- count/list accessor to read instead, so this scans by name and stops at
-- the first gap; 200 is just a sane hard backstop, never actually reached.
local TBB_FRAME_SCAN_CAP = 200

local function ApplyTBBVisibilityMirror()
    local cfg = DB()
    if not (cfg and cfg.mirrorCdmCooldownsVisibilityToBars) then
        RestoreAllTBBShowBlocks()
        return
    end

    local cdBar = GetCdmCooldownsBarFrame()
    local shouldHide = cdBar and cdBar:GetAlpha() == 0

    for i = 1, TBB_FRAME_SCAN_CAP do
        local wrap = _G["ECME_TBBWrap" .. i]
        if not wrap then break end
        EnsureTBBShowBlock(wrap)
        wrap._evlMirrorHide = shouldHide
        if shouldHide and wrap:IsShown() then wrap:Hide() end
    end
end

local mirrorHookInstalled = false
local mirrorRetryFrame

local function EnsureCDMVisibilityHook()
    if mirrorHookInstalled then return end
    local cdBar = GetCdmCooldownsBarFrame()
    if not cdBar then return end
    mirrorHookInstalled = true
    hooksecurefunc(cdBar, "SetAlpha", ApplyTBBVisibilityMirror)
end

-- The bar frame may not exist yet the first time the toggle is turned on
-- (very early login timing); retry on the next loading-screen transition,
-- which is always well after both addons are up.
local function EnsureMirrorRetry()
    if mirrorHookInstalled or mirrorRetryFrame then return end
    mirrorRetryFrame = CreateFrame("Frame")
    mirrorRetryFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    mirrorRetryFrame:SetScript("OnEvent", function(self)
        EnsureCDMVisibilityHook()
        if mirrorHookInstalled then
            ApplyTBBVisibilityMirror()
            self:UnregisterAllEvents()
        end
    end)
end

local function ApplyMirrorCdmVisibility()
    local cfg = DB()
    if not (cfg and cfg.mirrorCdmCooldownsVisibilityToBars) then
        -- Toggle off: touch nothing. In particular, never install the
        -- (permanent) CDM hook for a user who hasn't opted in -- only clean
        -- up frames a PRIOR "on" state left hooked.
        RestoreAllTBBShowBlocks()
        return
    end
    EnsureCDMVisibilityHook()
    if not mirrorHookInstalled then EnsureMirrorRetry() end
    ApplyTBBVisibilityMirror()
end

function EVL.ApplyTweaks()
    ApplyRunesSpecColor()
    ApplyDebuffNotDispellableColor()
    ApplyMirrorCdmVisibility()
end
