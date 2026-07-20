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

function EVL.ApplyQoL()
    ApplyDragonridingOverride()
    ApplyPlayedSuppression()
end
