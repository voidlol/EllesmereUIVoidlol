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
--  Resource Bar: Segmented Blocks
--  EllesmereUIResourceBars renders the "secondary" class-resource bar (combo
--  points, runes, holy power, etc.) as one continuous strip: every pip/rune
--  is built with border size 0, while a single outer border
--  (secondaryFrame._barBorder) wraps the whole bar and a single full-width
--  background/gap-fill layer (secondaryFrame._barBg / ERB.ApplyGapFills)
--  shows through the inter-pip gaps. The Dragonriding HUD's charge/Second
--  Wind rows (EllesmereUIBlizzardSkin_DragonRiding.lua) do the opposite:
--  each pip is its own independently-bordered block, separated by real
--  empty space. This toggle reproduces that look: after every rebuild,
--  give each pip/rune its own border (the bar's own configured border
--  style, read via the same _G._ERB_ResolveSecondaryCfg() BuildBars itself
--  uses, so per-spec overrides are respected) and hide the outer
--  border/background so the gaps read as empty space instead of a filled
--  seam.
--
--  EllesmereUIResourceBars' pip layout is rebuilt (BuildBars) not just from
--  ERB:ApplyAll() but also directly from several event handlers inside that
--  addon (spec change, zone change, shapeshift, max-power change) -- and
--  BuildBars is file-local, so it can't be hooked directly from here.
--  Instead this hooks ApplyAll for the common case (settings changes,
--  login) and separately watches the same handful of events, re-applying
--  next frame (C_Timer.After(0, ...)) once that out-of-band rebuild has
--  finished. Known gap: a one-frame flash back to the default segmented
--  look is possible on those paths; accepted trade-off for staying
--  entirely inside this addon rather than editing ResourceBars' source.
-------------------------------------------------------------------------------
local function GetERB()
    return EllesmereUI and EllesmereUI.Lite and EllesmereUI.Lite.GetAddon
        and EllesmereUI.Lite.GetAddon("EllesmereUIResourceBars", true)
end

-- pip -> true while we've stamped it with a block-style border, so an "off"
-- pass only ever touches pips this feature itself touched.
local blockStylePips = setmetatable({}, { __mode = "k" })

-- CreatePip()'s exact field/method signature (SetActive + ApplyBorder + a
-- non-nil _idx) is the only reliable way to pick pip/rune frames back out of
-- secondaryFrame:GetChildren() -- they're created anonymously (no global
-- name), unlike the border/tick/text-overlay frames also parented there.
local function IsResourcePip(child)
    return type(child) == "table" and type(child.SetActive) == "function"
        and type(child.ApplyBorder) == "function" and child._idx ~= nil
end

local function ApplyResourceBarBlockStyle()
    local secondaryFrame = _G.ERB_SecondaryFrame
    if not secondaryFrame then return end

    local cfg = DB()
    local on = cfg and cfg.resourceBarBlockStyle

    if on then
        local sp = _G._ERB_ResolveSecondaryCfg and _G._ERB_ResolveSecondaryCfg()
        if not sp then return end
        -- "Bar" type secondaries (Maelstrom Weapon, Devourer soul fragments,
        -- etc.) have no pips at all -- pips/runeFrames just sit hidden. Only
        -- switch the outer border/background off when we actually found a
        -- shown pip/rune to take over that job; otherwise a bar-type
        -- resource would be left with no border and no background at all.
        local found = 0
        for _, child in ipairs({ secondaryFrame:GetChildren() }) do
            if IsResourcePip(child) and child:IsShown() then
                child:ApplyBorder(sp.borderSize or 1, sp.borderR or 0, sp.borderG or 0,
                    sp.borderB or 0, sp.borderA or 1, sp.borderTexture)
                blockStylePips[child] = true
                found = found + 1
            end
        end
        if found > 0 then
            if secondaryFrame._barBorder then secondaryFrame._barBorder:SetShown(false) end
            if secondaryFrame._barBg then secondaryFrame._barBg:Hide() end
            if secondaryFrame._gapFills then
                for i = 1, #secondaryFrame._gapFills do secondaryFrame._gapFills[i]:Hide() end
            end
        end
    else
        for pip in pairs(blockStylePips) do
            pip:ApplyBorder(0, 0, 0, 0, 0)
        end
        wipe(blockStylePips)
        if secondaryFrame._barBorder then secondaryFrame._barBorder:SetShown(true) end
        if secondaryFrame._barBg then secondaryFrame._barBg:Show() end
        -- Gap-fill textures are left alone here -- ERB's own ApplyGapFills
        -- already re-derives their correct shown/hidden state (it runs
        -- unconditionally on every native rebuild); only the toggle-off
        -- path below needs to force that once for an instant restore.
    end
end

local erbHookInstalled = false
local erbEventFrame

local function EnsureERBHook()
    if erbHookInstalled then return end
    local erb = GetERB()
    if not (erb and erb.ApplyAll) then return end
    erbHookInstalled = true
    hooksecurefunc(erb, "ApplyAll", ApplyResourceBarBlockStyle)
end

-- Mirrors the event set EllesmereUIResourceBars reacts to with its own
-- out-of-band BuildBars() calls (see comment above). C_Timer.After(0, ...)
-- runs next frame, after that rebuild has definitely finished regardless of
-- frame event-dispatch ordering between the two addons.
local function EnsureERBEventWatcher()
    if erbEventFrame then return end
    erbEventFrame = CreateFrame("Frame")
    erbEventFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
    erbEventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    erbEventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
    erbEventFrame:RegisterUnitEvent("UNIT_MAXPOWER", "player")
    erbEventFrame:RegisterUnitEvent("UNIT_MAXHEALTH", "player")
    erbEventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    erbEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    erbEventFrame:SetScript("OnEvent", function()
        local cfg = DB()
        if not (cfg and cfg.resourceBarBlockStyle) then return end
        C_Timer.After(0, ApplyResourceBarBlockStyle)
    end)
end

-- The bar frame may not exist yet the first time the toggle is turned on
-- (very early login timing, or ResourceBars loads after Voidlol); retry on
-- the next loading-screen transition, matching the CDM mirror's same
-- pattern above.
local erbRetryFrame
local function EnsureERBRetry()
    if erbHookInstalled or erbRetryFrame then return end
    erbRetryFrame = CreateFrame("Frame")
    erbRetryFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    erbRetryFrame:SetScript("OnEvent", function(self)
        EnsureERBHook()
        if erbHookInstalled then self:UnregisterAllEvents() end
    end)
end

local resourceBarBlockStyleWasOn = false

local function ApplyResourceBarBlockStyleToggle()
    EnsureERBEventWatcher()
    EnsureERBHook()
    if not erbHookInstalled then EnsureERBRetry() end

    local cfg = DB()
    local isOn = cfg and cfg.resourceBarBlockStyle or false
    local wasOn = resourceBarBlockStyleWasOn
    resourceBarBlockStyleWasOn = isOn

    if isOn then
        ApplyResourceBarBlockStyle()
    elseif wasOn then
        -- Turning off: force one native rebuild so the outer
        -- border/background/gap-fills are restored exactly as ERB itself
        -- would draw them, instead of hand-reproducing that logic here.
        local erb = GetERB()
        if erb and erb.ApplyAll then erb:ApplyAll() end
    end
end

-------------------------------------------------------------------------------
--  Buffs: Independent Border Color (Player, Target, Focus, Pet, ToT, FoT, Boss)
--  EllesmereUIUnitFrames is still pre-12.1 on the client this ships for, so
--  auras render through the LEGACY path (CreateTargetAuras in
--  EllesmereUIUnitFrames.lua), not the 12.1 AuraKit/AuraContainers system --
--  an earlier version of this tweak targeted AuraKit and never had any
--  effect for exactly that reason. On the legacy path, both
--  frame.Buffs.PostUpdateButton and frame.Debuffs.PostUpdateButton call the
--  SAME closure, ApplyLegacyAuraBorder(button), which paints button.Border
--  from one shared setting (auraBorderR/G/B/A) -- no separate buff color,
--  and no isBuff branch at all. This wraps frame.Buffs.PostUpdateButton (the
--  same hook point the old, now-removed debuff tweak used on .Debuffs) and
--  recolors button.Border to flat black afterward, leaving .Debuffs (and its
--  own dispel-type recolor, ns.UF_ColorDebuffDispelBorder, which is only
--  ever wired to .Debuffs) untouched.
--
--  ApplyLegacyAuraBorder change-guards its own repaint on a per-button
--  generation stamp (button._euiABGen) that only advances on a REAL
--  EllesmereUIUnitFrames settings change -- flipping our own toggle never
--  bumps it, so a stale button would just keep whatever color it last had
--  forever (in either direction: turning this off would leave it stuck
--  black, since nothing else would ever repaint it back). Clearing
--  button._euiABGen right before calling the original forces a full
--  repaint from the CURRENT configured color every single time, so our
--  override always starts from a correct base with no bookkeeping of our
--  own needed. button._euiABGen is a plain field on a public Blizzard aura
--  button frame, safe to poke from outside.
-------------------------------------------------------------------------------
local BUFF_FRAME_NAMES = {
    "EllesmereUIUnitFrames_Player", "EllesmereUIUnitFrames_Target", "EllesmereUIUnitFrames_Focus",
    "EllesmereUIUnitFrames_Pet", "EllesmereUIUnitFrames_TargetTarget", "EllesmereUIUnitFrames_FocusTarget",
    "EllesmereUIUnitFrames_Boss1", "EllesmereUIUnitFrames_Boss2", "EllesmereUIUnitFrames_Boss3",
    "EllesmereUIUnitFrames_Boss4", "EllesmereUIUnitFrames_Boss5",
}

local wrappedBuffContainers = setmetatable({}, { __mode = "k" })

local function ApplyBuffBorderColorToButton(button)
    local cfg = DB()
    if not (cfg and cfg.buffBorderBlack) then return end
    local border = button and button.Border
    if not border then return end
    local EUI = _G.EllesmereUI
    if not (EUI and EUI.PP and EUI.PP.SetBorderColor) then return end
    EUI.PP.SetBorderColor(border, 0, 0, 0, 1)
end

local function HookBuffContainer(buffs)
    if not buffs or wrappedBuffContainers[buffs] then return end
    wrappedBuffContainers[buffs] = true
    local orig = buffs.PostUpdateButton
    buffs.PostUpdateButton = function(element, button, ...)
        if button then button._euiABGen = nil end
        if orig then orig(element, button, ...) end
        ApplyBuffBorderColorToButton(button)
    end
end

local function HookBuffContainers()
    for i = 1, #BUFF_FRAME_NAMES do
        local f = _G[BUFF_FRAME_NAMES[i]]
        if f and f.Buffs then HookBuffContainer(f.Buffs) end
    end
end

-- Forces every already-hooked container to re-run PostUpdateButton for its
-- current buttons right now (oUF Auras element convention), so a toggle
-- flipped mid-session repaints immediately instead of waiting for the next
-- natural aura update.
local function ForceRefreshHookedBuffContainers()
    for buffs in pairs(wrappedBuffContainers) do
        if buffs.ForceUpdate then buffs:ForceUpdate() end
    end
end

-- Defensive re-hook: if EllesmereUIUnitFrames ever rebuilds a Buffs
-- container from scratch (settings change, profile swap), frame.Buffs
-- becomes a brand-new object (CreateTargetAuras always creates one fresh),
-- so catch it via the addon's exposed global reload hook.
local reloadHooked = false
local function EnsureReloadFramesHook()
    if reloadHooked or not _G._EUF_ReloadFrames then return end
    reloadHooked = true
    local orig = _G._EUF_ReloadFrames
    _G._EUF_ReloadFrames = function(...)
        orig(...)
        HookBuffContainers()
        ForceRefreshHookedBuffContainers()
    end
end

-- Frames may not exist yet the very first time this runs (Voidlol's own
-- OnEnable racing EllesmereUIUnitFrames' own frame construction); retry on
-- the next loading-screen transition, matching this file's other retry
-- patterns (EnsureERBRetry, EnsureMirrorRetry).
local retryFrame
local function EnsureBuffBorderRetry()
    if retryFrame then return end
    retryFrame = CreateFrame("Frame")
    retryFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    retryFrame:SetScript("OnEvent", function()
        HookBuffContainers()
        ForceRefreshHookedBuffContainers()
    end)
end

-------------------------------------------------------------------------------
--  Buffs: Independent Border Color -- 12.1 path
--  On 12.1, EllesmereUIUnitFrames migrates aura rendering to
--  EllesmereUI.AuraKit/AuraContainers (EUI_UnitFrames_AuraContainers.lua) and
--  frame.Buffs stops existing, so the legacy hook above has nothing left to
--  grab. Untested (no 12.1 client to run this against yet), written from
--  reading AuraKit's source alongside the legacy path above -- fix forward
--  if it turns out wrong once 12.1 actually ships.
--
--  BuildStyle (in EUI_UnitFrames_AuraContainers.lua) builds one style table
--  per unit+polarity and registers it into EllesmereUI.AuraKit.styles, keyed
--  "uf:<unit>:<HELPFUL|HARMFUL>". Both HELPFUL (buff) and HARMFUL (debuff)
--  styles share the same single border color (auraBorderR/G/B/A) -- same
--  bug as the legacy path, just a different mechanism.
--
--  style.applyExtra(button, d, style) is AuraKit's own per-button hook
--  (ApplyStyleToRegions calls it right after painting the button's border
--  from style.border, both at button creation AND on every restyle), and `d`
--  is the per-button state table that carries d.borderHost -- the actual
--  border frame -- so wrapping applyExtra gives a hook point at exactly the
--  right moment, with the same PP-based border host the legacy path paints,
--  without needing any private AuraKit internals.
--
--  Getting styles in the first place needs the same permanently-empty proxy
--  trick as the (removed) first attempt at this feature, for the same
--  reason: AK.styles only gets a fresh WRITE when BuildStyle's own settings
--  fingerprint changes, and a metatable's __newindex only fires for keys a
--  table doesn't already hold -- so this still parks a proxy in
--  AuraKit.styles's place to catch every write, first or hundredth. Unlike
--  that attempt, this only WRAPS style.applyExtra once (marked via
--  style._evlBuffBorderHooked) rather than mutating style.border -- the
--  wrap survives on that same table object even through fingerprint-skipped
--  passes that never call AK.styles[key]=... again, so no separate
--  reapply-on-toggle plumbing is needed: applyExtra reads DB() live every
--  time it runs. AK.RestyleSoon(key) (AuraKit's own public repaint queue) is
--  called once here to catch styles already sitting in AK.styles before the
--  toggle changed and force an immediate repaint through the now-wrapped
--  applyExtra, exactly mirroring ForceRefreshHookedBuffContainers's role in
--  the legacy path above.
-------------------------------------------------------------------------------
local BUFF_STYLE_PATTERN = "^uf:.-:HELPFUL$"

local function HookBuffStyleApplyExtra(style)
    if not style or style._evlBuffBorderHooked then return end
    style._evlBuffBorderHooked = true
    local orig = style.applyExtra
    style.applyExtra = function(button, d, st)
        if orig then orig(button, d, st) end
        local cfg = DB()
        if not (cfg and cfg.buffBorderBlack) then return end
        local b = st.border
        local EUI = _G.EllesmereUI
        if not (b and d.borderHost and EUI and EUI.ApplySecretSafeBorderStyle) then return end
        EUI.ApplySecretSafeBorderStyle(d.borderHost, d, b.size or 1, 0, 0, 0, 1,
            b.texture or "solid", b.offsetX, b.offsetY, b.shiftX, b.shiftY,
            "unitframes", b.size or 1)
    end
end

local buffStyleProxyInstalled = false
local buffStylesReal -- the real backing table our proxy writes through to

local function InstallBuffStyleProxy()
    if buffStyleProxyInstalled then return end
    local EUI = _G.EllesmereUI
    local AK = EUI and EUI.AuraKit
    if not (AK and AK.styles) then return end
    buffStyleProxyInstalled = true

    buffStylesReal = AK.styles
    AK.styles = setmetatable({}, {
        __index = buffStylesReal,
        __newindex = function(_, key, style)
            if type(key) == "string" and type(style) == "table" and key:match(BUFF_STYLE_PATTERN) then
                HookBuffStyleApplyExtra(style)
            end
            rawset(buffStylesReal, key, style)
        end,
    })
end

local function ForceRestyleBuffStyles()
    local EUI = _G.EllesmereUI
    local AK = EUI and EUI.AuraKit
    if not (AK and buffStylesReal) then return end
    for key, style in pairs(buffStylesReal) do
        if type(key) == "string" and type(style) == "table" and key:match(BUFF_STYLE_PATTERN) then
            HookBuffStyleApplyExtra(style)
            AK.RestyleSoon(key)
        end
    end
end

local function Apply121BuffBorderColor()
    InstallBuffStyleProxy()
    ForceRestyleBuffStyles()
end

-------------------------------------------------------------------------------
-- No EllesmereUI.IS_121-style build flag actually exists on the shipped
-- addon (checked -- it's nowhere in EllesmereUI.lua/EllesmereUI_Lite.lua), so
-- gating on it always fell through to the legacy path below, whose hook
-- target (frame.Buffs) no longer exists once EllesmereUIUnitFrames renders
-- through AuraKit -- silently doing nothing. EllesmereUI.AuraKit itself is a
-- real, always-present table once EllesmereUI is loaded (EllesmereUI's own
-- pre-12.1 ClientGate failsafe means only 12.1+ clients ever get this far
-- anyway), so its presence is what actually distinguishes the two paths.
-------------------------------------------------------------------------------
local function ApplyBuffBorderColor()
    local EUI = _G.EllesmereUI
    if EUI and EUI.AuraKit then
        Apply121BuffBorderColor()
        return
    end
    HookBuffContainers()
    EnsureReloadFramesHook()
    EnsureBuffBorderRetry()
    ForceRefreshHookedBuffContainers()
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

-------------------------------------------------------------------------------
--  Nameplates: Custom Friendly Raid Marker Size
--  EllesmereUINameplates sizes a friendly plate's raid target marker off the
--  shared icon-"slot" size for whatever position it's assigned to (top/left/
--  right/topleft/topright) -- the SAME size used by debuff/buff/CC icons
--  parked in that slot (GetRaidMarkerSize in EllesmereUINameplates.lua:1012
--  reads p[pos.."SlotSize"]) -- so there's no size dedicated to the marker
--  alone. FriendlyFrame:UpdateRaidIcon() (EllesmereUINameplatesFriendly.lua)
--  is the one place that sizes+shows it: SetRaidTargetIconTexture then
--  raidFrame:SetSize(sz, sz). This overrides just that size, on friendly
--  plates only, right after the native call finishes each time. self.raid
--  (the actual icon texture) is anchored TOPLEFT/BOTTOMRIGHT to raidFrame
--  with a 1px inset, so it stretches to match automatically -- nothing else
--  needs touching.
--
--  FriendlyFrame itself is a file-local mixin table (never exposed), so
--  there's no single prototype to hook; Mixin(plate, FriendlyFrame) copies
--  UpdateRaidIcon onto each PLATE as a real per-table field instead, which
--  hooksecurefunc can target per-plate. EllesmereUINameplates registers its
--  private ns on EllesmereUI._ModuleNS["EllesmereUINameplates"]
--  (EllesmereUINameplates.lua:4) specifically so other addons can reach in
--  like this; ns.friendlyPlates ([unit]=plate) is its live plate registry.
--
--  Plates are drawn from a pool (Acquire/Release) and Mixin only ever runs
--  once per physical frame (plate._mixedIn), so each frame only needs
--  hooking once -- hookedRaidIconPlates (weak-keyed) tracks that. New plates
--  are caught by sweeping ns.friendlyPlates off our OWN NAME_PLATE_UNIT_ADDED
--  watcher (deferred one frame so the parent addon's own handler -- which is
--  what actually populates friendlyPlates -- has definitely already run)
--  rather than wrapping ns.TryAddFriendlyPlate: a few of that function's own
--  call sites inside EllesmereUINameplatesFriendly.lua invoke the file-local
--  version directly, which would bypass a wrap on the exported ns field.
-------------------------------------------------------------------------------
local function GetNameplatesNS()
    local EUI = _G.EllesmereUI
    return EUI and EUI._ModuleNS and EUI._ModuleNS["EllesmereUINameplates"]
end

local hookedRaidIconPlates = setmetatable({}, { __mode = "k" })

local function ApplyFriendlyRaidMarkerSize(self)
    local cfg = DB()
    if not (cfg and cfg.friendlyRaidMarkerSizeEnabled) then return end
    local raidFrame = self.raidFrame
    if not (raidFrame and raidFrame:IsShown()) then return end
    local sz = cfg.friendlyRaidMarkerSize or 24
    raidFrame:SetSize(sz, sz)
end

local function SweepFriendlyRaidIconPlates()
    local npNS = GetNameplatesNS()
    local plates = npNS and npNS.friendlyPlates
    if not plates then return end
    for _, plate in pairs(plates) do
        if plate.UpdateRaidIcon and not hookedRaidIconPlates[plate] then
            hookedRaidIconPlates[plate] = true
            hooksecurefunc(plate, "UpdateRaidIcon", ApplyFriendlyRaidMarkerSize)
        end
    end
end

-- Forces every already-hooked plate to redraw its raid icon right now, so a
-- toggle/slider change takes effect immediately (including handing sizing
-- back to EllesmereUINameplates' own slot size when turned off) instead of
-- waiting for the next natural RAID_TARGET_UPDATE.
local function RefreshFriendlyRaidIconPlates()
    local npNS = GetNameplatesNS()
    local plates = npNS and npNS.friendlyPlates
    if not plates then return end
    for _, plate in pairs(plates) do
        if plate.UpdateRaidIcon then plate:UpdateRaidIcon() end
    end
end

-------------------------------------------------------------------------------
--  Nameplates: Custom Friendly Raid Marker Size -- Name Only mode
--  EllesmereUINameplates' friendly plates default to "Name Only" mode
--  (friendlyNameOnly = true in its defaults) -- friendlyNameOnly must be
--  explicitly turned OFF for the custom FriendlyFrame path above (with its
--  own raidFrame) to ever run at all. In Name Only mode ns.friendlyPlates
--  stays permanently empty and the marker seen on friendly plates is
--  Blizzard's OWN default CompactUnitFrame element, nameplate.UnitFrame.
--  RaidTargetFrame -- confirmed by EllesmereUINameplatesFriendly.lua's own
--  comment on the event it re-registers for that path ("Blizzard's
--  RaidTargetFrame is the marker display on this path"). EllesmereUI leaves
--  that frame otherwise untouched (it only strips unrelated events off the
--  surrounding UnitFrame), so this hooks it directly instead.
--
--  RaidTargetFrame is a plain (non-forbidden) Frame sized by Blizzard's
--  template with a child Texture region (.Texture) that carries its OWN
--  fixed size independent of the parent -- resizing the outer frame alone
--  does nothing visible, so both get resized together. hooksecurefunc on
--  its Show catches every native redraw regardless of whether Blizzard's
--  update path is a bare function or a frame-mixin method internally.
--  Nameplate UnitFrames are pooled/reused by Blizzard itself (a small fixed
--  set of physical frames), so hooking is one-time-per-frame here too.
--
--  The frame's size at first-hook time is captured as its "native" size so
--  turning the toggle off restores exactly what Blizzard shipped, rather
--  than a guessed hardcoded 16x16 that could be wrong on some future client
--  build. Filtered to friendly units only (UnitCanAttack check) so this
--  never touches enemy plates, which don't use this Name-Only path anyway.
-------------------------------------------------------------------------------
local hookedBlizzRaidFrames = setmetatable({}, { __mode = "k" })

-- Blizzard's parentKey for the icon texture region inside RaidTargetFrame
-- isn't confirmed for this client build, so .Texture/.texture are tried
-- first and a plain region scan is the fallback -- resizing only the outer
-- frame wouldn't grow the icon, since the texture carries its own fixed
-- size independent of its parent.
local function GetRaidTargetFrameTexture(rtf)
    local tex = rtf.Texture or rtf.texture
    if tex then return tex end
    for _, region in ipairs({ rtf:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "Texture" then
            return region
        end
    end
end

local function ApplyBlizzFriendlyRaidMarkerSize(rtf)
    if not rtf:IsShown() then return end
    local uf = rtf:GetParent()
    local unit = uf and (uf.displayedUnit or uf.unit)
    if not unit or UnitCanAttack("player", unit) then return end
    local cfg = DB()
    local tex = GetRaidTargetFrameTexture(rtf)
    if cfg and cfg.friendlyRaidMarkerSizeEnabled then
        local sz = cfg.friendlyRaidMarkerSize or 24
        rtf:SetSize(sz, sz)
        if tex then tex:SetSize(sz, sz) end
    elseif rtf._evlNativeW then
        rtf:SetSize(rtf._evlNativeW, rtf._evlNativeH)
        if tex and rtf._evlNativeTexW then tex:SetSize(rtf._evlNativeTexW, rtf._evlNativeTexH) end
    end
end

local function HookBlizzRaidTargetFrame(rtf)
    if not rtf or hookedBlizzRaidFrames[rtf] then return end
    hookedBlizzRaidFrames[rtf] = true
    rtf._evlNativeW, rtf._evlNativeH = rtf:GetSize()
    local tex = GetRaidTargetFrameTexture(rtf)
    if tex then rtf._evlNativeTexW, rtf._evlNativeTexH = tex:GetSize() end
    hooksecurefunc(rtf, "Show", ApplyBlizzFriendlyRaidMarkerSize)
end

-- One pass: hooks any newly-seen nameplate's Blizzard RaidTargetFrame AND
-- (re)applies current sizing to every one already shown -- covers both the
-- lifecycle watcher below and an immediate settings-change refresh.
local function SweepBlizzRaidTargetFrames()
    local plates = C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates()
    if not plates then return end
    for _, nameplate in ipairs(plates) do
        local uf = nameplate.UnitFrame
        local rtf = uf and not uf:IsForbidden() and uf.RaidTargetFrame
        if rtf then
            HookBlizzRaidTargetFrame(rtf)
            ApplyBlizzFriendlyRaidMarkerSize(rtf)
        end
    end
end

local npWatcher
local function EnsureFriendlyRaidIconWatcher()
    if npWatcher then return end
    npWatcher = CreateFrame("Frame")
    npWatcher:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    npWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    npWatcher:SetScript("OnEvent", function()
        C_Timer.After(0, function()
            SweepFriendlyRaidIconPlates()
            SweepBlizzRaidTargetFrames()
        end)
    end)
end

local function ApplyFriendlyRaidMarkerSizeToggle()
    EnsureFriendlyRaidIconWatcher()
    SweepFriendlyRaidIconPlates()
    RefreshFriendlyRaidIconPlates()
    SweepBlizzRaidTargetFrames()
end

function EVL.ApplyTweaks()
    ApplyRunesSpecColor()
    ApplyResourceBarBlockStyleToggle()
    ApplyBuffBorderColor()
    ApplyMirrorCdmVisibility()
    ApplyFriendlyRaidMarkerSizeToggle()
end
