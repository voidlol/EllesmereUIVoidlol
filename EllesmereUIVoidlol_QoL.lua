-------------------------------------------------------------------------------
--  EllesmereUIVoidlol_QoL.lua
--  Small quality-of-life tweaks that don't warrant their own dedicated file.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EVL = ns.EVL

local function DB()
    local d = EVL.DB and EVL.DB()
    return d and d.qol
end

-------------------------------------------------------------------------------
--  Actual Dragonriding Visibility
--  EllesmereUI.IsAirborneSkyriding() gates "Hide when Dragonriding" on
--  IsFlying() -- bars only hide once you've actually taken off, not the
--  moment you're on a skyriding-capable mount. This overrides it to drop
--  that requirement, matching "hide whenever I *can* dragonride" instead of
--  "hide only once I'm already airborne". Written to hold regardless of
--  whether EllesmereUI's own predicate changes shape in a future update --
--  cached once, restored verbatim when the toggle is turned back off.
--
--  Uses EllesmereUI.IsPlayerMountedLike() instead of plain IsMounted(): a
--  druid's Flight Form is a shapeshift, not a mount, so IsMounted() alone
--  reports false while skyriding as a druid (same gap EllesmereUI itself
--  already works around in IsPlayerSkyriding()/CheckVisibilityOptionsNonMacro,
--  just not in this particular predicate).
-------------------------------------------------------------------------------
local originalIsAirborneSkyriding

local function OverriddenIsAirborneSkyriding()
    local EUI = _G.EllesmereUI
    local mountedLike = (EUI and EUI.IsPlayerMountedLike and EUI.IsPlayerMountedLike())
        or (IsMounted and IsMounted())
    if not mountedLike then return false end
    if C_PlayerInfo and C_PlayerInfo.GetGlidingInfo then
        local _, canGlide = C_PlayerInfo.GetGlidingInfo()
        return canGlide == true
    end
    return true
end

local function ApplyDragonridingOverride()
    local EUI = _G.EllesmereUI
    if not (EUI and EUI.IsAirborneSkyriding) then return end
    if not originalIsAirborneSkyriding then
        originalIsAirborneSkyriding = EUI.IsAirborneSkyriding
    end

    local cfg = DB()
    if cfg and cfg.actualDragonridingVisibility then
        EUI.IsAirborneSkyriding = OverriddenIsAirborneSkyriding
    else
        EUI.IsAirborneSkyriding = originalIsAirborneSkyriding
    end
end

-------------------------------------------------------------------------------
--  Suppress Auto /played
--  Some addons (confirmed here: XPBarEnhanced) call RequestTimePlayed()
--  unconditionally on every login for their own tracking. Two message-filter
--  attempts (ChatFrame_AddMessageEventFilter, then ChatFrameUtil.Add
--  MessageEventFilter) both failed to catch the resulting "You have
--  played..." text -- it evidently never actually flows through
--  CHAT_MSG_SYSTEM as a filterable chat message on this client at all.
--
--  Different approach, one level lower: TIME_PLAYED_MSG only ever gets
--  displayed because a chat frame is registered for that event and prints
--  it in reaction (verified working precedent: ZygorGuidesViewer's own
--  Widgets/timeplayed.lua unregisters ChatFrame1 from TIME_PLAYED_MSG right
--  before its own RequestTimePlayed() call, and re-registers once its
--  response arrives). Generalized here: wrap the GLOBAL RequestTimePlayed
--  so EVERY caller's request -- not just our own -- gets the same
--  unregister/reregister bracket, unless it's the player's own /played
--  (hooked below), which is let through completely untouched so the normal
--  reply still displays normally.
-------------------------------------------------------------------------------
local NUM_CHAT_FRAMES = _G.NUM_CHAT_WINDOWS or 10

local function ForEachChatFrame(fn)
    for i = 1, NUM_CHAT_FRAMES do
        local cf = _G["ChatFrame" .. i]
        if cf then fn(cf) end
    end
end

local userRequestedPlayed = false
local playedSlashHooked = false
-- Blizzard's real /played binding is "TIMEPLAYED"; "PLAYED" is checked too
-- as a defensive fallback in case that ever changes -- an absent key is a
-- harmless no-op either way.
local PLAYED_SLASH_KEYS = { "TIMEPLAYED", "PLAYED" }

local function HookPlayedSlashCommand()
    if playedSlashHooked or not SlashCmdList then return end
    playedSlashHooked = true
    for _, key in ipairs(PLAYED_SLASH_KEYS) do
        local orig = SlashCmdList[key]
        if orig then
            SlashCmdList[key] = function(...)
                userRequestedPlayed = true
                return orig(...)
            end
        end
    end
end

local originalRequestTimePlayed
local restoreListener

local function HookedRequestTimePlayed(...)
    if userRequestedPlayed then
        -- Deliberate manual /played: let it through completely untouched,
        -- one-shot (the next call after this one goes back to suppressed).
        userRequestedPlayed = false
        return originalRequestTimePlayed(...)
    end

    -- Background/addon-triggered: hide the reply from every chat frame that
    -- currently listens for it, for exactly this one round-trip.
    local unregistered = {}
    ForEachChatFrame(function(cf)
        if cf.IsEventRegistered and cf:IsEventRegistered("TIME_PLAYED_MSG") then
            cf:UnregisterEvent("TIME_PLAYED_MSG")
            unregistered[#unregistered + 1] = cf
        end
    end)

    local function Restore()
        for _, cf in ipairs(unregistered) do
            cf:RegisterEvent("TIME_PLAYED_MSG")
        end
    end

    if #unregistered > 0 then
        if not restoreListener then
            restoreListener = CreateFrame("Frame")
        end
        restoreListener:SetScript("OnEvent", function()
            restoreListener:UnregisterEvent("TIME_PLAYED_MSG")
            Restore()
        end)
        restoreListener:RegisterEvent("TIME_PLAYED_MSG")
        -- Safety net: RegisterEvent is idempotent, so a redundant Restore()
        -- here (if the listener already fired) is harmless.
        C_Timer.After(5, Restore)
    end

    return originalRequestTimePlayed(...)
end

local function EnsurePlayedSuppressionHook()
    if not originalRequestTimePlayed then
        originalRequestTimePlayed = _G.RequestTimePlayed
    end
    _G.RequestTimePlayed = HookedRequestTimePlayed
    HookPlayedSlashCommand()
end

local function RemovePlayedSuppressionHook()
    if originalRequestTimePlayed then
        _G.RequestTimePlayed = originalRequestTimePlayed
    end
    -- The /played slash hook stays installed (harmless once unhooked -- it
    -- only ever sets a flag nothing reads anymore) rather than unwinding a
    -- hook chain another addon may have layered on top of by now.
end

local function ApplyPlayedSuppression()
    local cfg = DB()
    if cfg and cfg.suppressAutoPlayed then
        EnsurePlayedSuppressionHook()
    else
        RemovePlayedSuppressionHook()
    end
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
-------------------------------------------------------------------------------
local hookedTBBFrames = setmetatable({}, { __mode = "k" })

local function EnsureTBBShowBlock(wrap)
    if hookedTBBFrames[wrap] then return end
    hookedTBBFrames[wrap] = true
    local origShow = wrap.Show
    wrap.Show = function(self, ...)
        if self._evlMirrorHide then return end
        return origShow(self, ...)
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
    local cdBar = GetCdmCooldownsBarFrame()
    local shouldHide = cfg and cfg.mirrorCdmCooldownsVisibilityToBars
        and cdBar and cdBar:GetAlpha() == 0

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

-- The bar frame may not exist yet the first time ApplyQoL runs (very early
-- login timing); retry on the next loading-screen transition, which is
-- always well after both addons are up.
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
    EnsureCDMVisibilityHook()
    if not mirrorHookInstalled then EnsureMirrorRetry() end
    ApplyTBBVisibilityMirror()
end

function EVL.ApplyQoL()
    ApplyDragonridingOverride()
    ApplyPlayedSuppression()
    ApplyRunesSpecColor()
    ApplyDebuffNotDispellableColor()
    ApplyMirrorCdmVisibility()
end
