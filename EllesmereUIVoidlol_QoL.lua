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

function EVL.ApplyQoL()
    ApplyDragonridingOverride()
end
