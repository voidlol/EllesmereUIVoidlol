-------------------------------------------------------------------------------
--  EllesmereUIVoidlol_Castbar.lua
--
--  Two modes, selected by cfg.overlayMode:
--
--  OVERLAY ON  -- The parent addon's oUF target castbar element is DISABLED
--    (EllesmereUIUnitFrames_Target:DisableElement("Castbar")) and its background
--    hidden, so the parent does zero event/OnUpdate work on it. In its place we
--    run our OWN standalone, fully transparent castbar overlaid on the target
--    unit frame (matching its width/height): spell name (left), remaining time
--    (right) and a spark -- nothing else. The bar copies the parent target
--    castbar's configured name/time fonts+colors so text styling is preserved.
--    It is driven by our own UNIT_SPELLCAST_* handlers; the per-frame OnUpdate
--    exists ONLY while the target is actively casting (spark + timer), which is
--    the whole point of this rewrite -- the old code re-styled the parent bar
--    every single frame regardless of cast state.
--
--  OVERLAY OFF -- The parent castbar is left fully intact and oUF-driven; we
--    only decorate its icon (size / border / detach / desaturate + "X" on
--    uninterruptible) via wrapped Post* callbacks. No OnUpdate driver.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EVL = ns.EVL

local FALLBACK_ICON = 136243 -- Interface\ICONS\Trade_Engineering

-- Live parent-addon frames (re-resolved lazily; the target frame is built by
-- EllesmereUIUnitFrames inside its own PLAYER_LOGIN handler).
local targetFrame      -- _G.EllesmereUIUnitFrames_Target (an oUF object)
local parentCastbar    -- targetFrame.Castbar (parent's StatusBar)
local parentCastbarBg  -- parentCastbar:GetParent()

local overlay          -- our standalone overlay bar (created lazily)
local parentDisabled = false -- whether we've DisableElement'd the parent castbar

-- Parent-icon decoration state (OVERLAY OFF path only)
local pIconFS          -- uninterruptible text overlay on the PARENT icon
local pOrigIconPoint   -- parent icon's original anchor, captured once
local pOrigIconSize

local InstallHooks

-- Maps a detach side to { icon's own anchor point, bar's anchor point }. Both
-- points sit at the axis center, so a (0,0) offset centres the icon on the
-- bar's height/width; x/y then nudge from there.
local ANCHOR_MAP = {
    RIGHT  = { "LEFT",   "RIGHT"  },
    LEFT   = { "RIGHT",  "LEFT"   },
    TOP    = { "BOTTOM", "TOP"    },
    BOTTOM = { "TOP",    "BOTTOM" },
}

-------------------------------------------------------------------------------
--  DB helper / frame resolution
-------------------------------------------------------------------------------
local function DB()
    local d = EVL.DB and EVL.DB()
    return d and d.castbar
end

local function ResolveFrames()
    local tf = _G.EllesmereUIUnitFrames_Target
    if not tf then return nil end
    targetFrame = tf
    parentCastbar = tf.Castbar
    parentCastbarBg = parentCastbar and parentCastbar:GetParent() or nil
    return tf
end

-- Reads a font (path,size,flags) + colour off a parent FontString, with a
-- global-font fallback so we never end up with an unstyled string.
local function CopyFontFrom(src, dstFS)
    local path, size, flags
    if src and src.GetFont then path, size, flags = src:GetFont() end
    if not path then
        path = (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
        size = 12
        flags = "OUTLINE"
    end
    dstFS:SetFont(path, size, flags)
    if src and src.GetTextColor then
        dstFS:SetTextColor(src:GetTextColor())
    else
        dstFS:SetTextColor(1, 1, 1, 1)
    end
end

-------------------------------------------------------------------------------
--  OVERLAY MODE: our own standalone transparent castbar
--
--  Driven by the engine's timer-duration StatusBar API (SetTimerDuration +
--  duration objects) exactly like oUF does for non-player units. This is
--  mandatory on current retail: UnitCastingInfo's startTime/endTime are now
--  "secret" values that tainted addon code may not do arithmetic on, so we must
--  never compute progress ourselves -- the StatusBar animates from the duration
--  object and the spark simply tracks the fill texture's edge.
-------------------------------------------------------------------------------
local SMOOTHING     = Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate
local DIR_ELAPSED   = Enum and Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.ElapsedTime
local DIR_REMAINING = Enum and Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.RemainingTime

local OnOverlayUpdate  -- fwd

local function EnsureOverlay()
    if overlay then return overlay end
    if not targetFrame then return nil end

    -- A StatusBar (not a plain Frame) so we can use SetTimerDuration; its fill
    -- is fully transparent so only our name/time/spark show.
    local o = CreateFrame("StatusBar", "EllesmereUIVoidlol_TargetCastbar", targetFrame)
    o:Hide()
    o:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    o:SetStatusBarColor(1, 1, 1, 0)
    local fillTex = o:GetStatusBarTexture()
    if fillTex then fillTex:SetHorizTile(false) end

    -- Spell name (left) and remaining time (right). Fonts copied from the
    -- parent bar in RefreshOverlayText so configured styling is preserved.
    local nameFS = o:CreateFontString(nil, "OVERLAY")
    nameFS:SetJustifyH("LEFT")
    nameFS:SetWordWrap(false)
    nameFS:SetMaxLines(1)
    o.nameFS = nameFS

    local timeFS = o:CreateFontString(nil, "OVERLAY")
    timeFS:SetJustifyH("RIGHT")
    timeFS:SetWordWrap(false)
    timeFS:SetMaxLines(1)
    o.timeFS = timeFS

    -- Spark tracks the (invisible) fill texture's leading edge automatically,
    -- so it needs no per-frame repositioning.
    local spark = o:CreateTexture(nil, "OVERLAY", nil, 7)
    spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    spark:SetBlendMode("ADD")
    spark:SetVertexColor(1, 1, 1, 1)
    spark:SetAlpha(1)
    spark:SetSize(20, 20)
    if fillTex then spark:SetPoint("CENTER", fillTex, "RIGHT", 0, 0) end
    spark:Hide()
    o.spark = spark

    -- Icon (our own; honours the icon settings).
    local iconFrame = CreateFrame("Frame", nil, o)
    local iconBg = iconFrame:CreateTexture(nil, "BACKGROUND")
    iconBg:SetAllPoints()
    iconBg:SetColorTexture(0, 0, 0, 1)
    local PP = EllesmereUI and EllesmereUI.PP
    if PP and PP.CreateBorder then PP.CreateBorder(iconFrame, 0, 0, 0, 1) end
    local iconTex = iconFrame:CreateTexture(nil, "ARTWORK")
    iconTex:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 1, -1)
    iconTex:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -1, 1)
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    iconFrame:Hide()
    o.iconFrame = iconFrame
    o.iconTex = iconTex

    -- "X"-style uninterruptible text over the icon.
    local iconFS = iconFrame:CreateFontString(nil, "OVERLAY")
    iconFS:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
    iconFS:Hide()
    o.iconFS = iconFS

    -- Dedicated event driver frame (registered only while overlay is active).
    o._driver = CreateFrame("Frame")

    overlay = o
    return o
end

-- Copies the parent bar's configured name/time fonts + colours and anchors the
-- two strings to the left/right of the (frame-sized) overlay.
local function RefreshOverlayText()
    if not overlay then return end
    CopyFontFrom(parentCastbar and parentCastbar.Text, overlay.nameFS)
    CopyFontFrom(parentCastbar and parentCastbar.Time, overlay.timeFS)

    overlay.nameFS:ClearAllPoints()
    overlay.nameFS:SetPoint("LEFT", overlay, "LEFT", 4, 0)
    overlay.nameFS:SetPoint("RIGHT", overlay, "RIGHT", -4, 0)

    overlay.timeFS:ClearAllPoints()
    overlay.timeFS:SetPoint("RIGHT", overlay, "RIGHT", -4, 0)
end

-- Applies icon size / border / anchor and the desaturate + uninterruptible-text
-- state (the latter depends on the live cast's notInterruptible flag).
local function RefreshOverlayIcon()
    local cfg = DB()
    if not overlay or not cfg then return end
    local iconFrame = overlay.iconFrame
    local PP = EllesmereUI and EllesmereUI.PP

    local size = cfg.iconSize or 32
    iconFrame:SetSize(size, size)

    iconFrame:ClearAllPoints()
    -- Non-detached default: right, OUTSIDE the frame (== detach RIGHT, 0 offset).
    local side = cfg.detachIcon and (cfg.detachAnchor or "RIGHT") or "RIGHT"
    local pair = ANCHOR_MAP[side] or ANCHOR_MAP.RIGHT
    local ox = cfg.detachIcon and (cfg.detachXOffset or 0) or 0
    local oy = cfg.detachIcon and (cfg.detachYOffset or 0) or 0
    iconFrame:SetPoint(pair[1], overlay, pair[2], ox, oy)

    if PP and PP.SetBorderSize then PP.SetBorderSize(iconFrame, cfg.iconBorderWidth or 1) end

    -- notInterruptible may be a "secret" boolean from the cast API, so it is
    -- only ever handed to widget setters (SetDesaturated / SetAlphaFromBoolean),
    -- never used in boolean arithmetic.
    local unint = overlay._notInterruptible
    if cfg.desaturateUninterruptible and unint ~= nil then
        overlay.iconTex:SetDesaturated(unint)
    else
        overlay.iconTex:SetDesaturated(false)
    end

    -- Uninterruptible text overlay
    local fs = overlay.iconFS
    local fontKey = cfg.uninterruptibleTextFont or "__global"
    local fontPath
    if fontKey == "__global" then
        fontPath = (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
    else
        fontPath = (EllesmereUI.ResolveFontName and EllesmereUI.ResolveFontName(fontKey)) or "Fonts\\FRIZQT__.TTF"
    end
    fs:SetFont(fontPath, cfg.uninterruptibleTextSize or 12, "OUTLINE")
    fs:SetTextColor(cfg.uninterruptibleTextR or 1, cfg.uninterruptibleTextG or 0.2, cfg.uninterruptibleTextB or 0.2, 1)
    fs:SetText(cfg.uninterruptibleText or "X")
    fs:SetShown(cfg.showUninterruptibleText and true or false)
    if cfg.showUninterruptibleText and unint ~= nil and fs.SetAlphaFromBoolean then
        fs:SetAlphaFromBoolean(unint, 1, 0)
    else
        fs:SetAlpha(cfg.showUninterruptibleText and 1 or 0)
    end
end

local function LayoutOverlay()
    if not overlay or not targetFrame then return end
    overlay:ClearAllPoints()
    overlay:SetAllPoints(targetFrame)
    overlay:SetFrameStrata(targetFrame:GetFrameStrata())
    overlay:SetFrameLevel(targetFrame:GetFrameLevel() + 20)
end

local function HideCast()
    if not overlay then return end
    overlay:SetScript("OnUpdate", nil)
    overlay.spark:Hide()
    overlay.iconFrame:Hide()
    overlay.nameFS:SetText("")
    overlay.timeFS:SetText("")
    overlay._casting = nil
    overlay:Hide()
end

-- Only the numeric timer text is updated per frame; the StatusBar fill (and the
-- spark anchored to it) are animated by the engine from the duration object.
OnOverlayUpdate = function(self)
    local d = self.GetTimerDuration and self:GetTimerDuration()
    if d then
        self.timeFS:SetFormattedText("%.1f", d:GetRemainingDuration())
    end
end

-- Reads whatever the target is currently casting/channelling and shows the
-- overlay. Used for start events and target changes. Never touches the secret
-- start/end times -- progress comes entirely from the duration object.
local function EvaluateCast()
    if not overlay then return end
    local name, text, texture, _, _, _, _, notInterruptible = UnitCastingInfo("target")
    local channel, empowered, duration, direction = false, false, nil, DIR_ELAPSED
    if name then
        duration = UnitCastingDuration("target")
    else
        local isEmpowered
        name, text, texture, _, _, _, notInterruptible, _, isEmpowered = UnitChannelInfo("target")
        if name then
            channel = true
            if isEmpowered then
                empowered = true
                duration = UnitEmpoweredChannelDuration("target")
                direction = DIR_ELAPSED
            else
                duration = UnitChannelDuration("target")
                direction = DIR_REMAINING
            end
        end
    end
    if not name or not duration then
        HideCast()
        return
    end

    overlay._casting = true
    overlay._channel = channel
    overlay._empowered = empowered
    overlay._direction = direction
    overlay._notInterruptible = notInterruptible

    overlay.nameFS:SetText(text or name or "")
    overlay.iconTex:SetTexture(texture or FALLBACK_ICON)
    overlay.iconFrame:Show()
    overlay.spark:SetSize(20, math.max(14, (overlay:GetHeight() or 14) * 1.35))
    overlay.spark:Show()
    overlay:SetTimerDuration(duration, SMOOTHING, direction)
    RefreshOverlayIcon()
    overlay:Show()
    overlay:SetScript("OnUpdate", OnOverlayUpdate)
    OnOverlayUpdate(overlay)
end

-- Pushback / channel-length change: re-fetch the duration object and re-arm the
-- timer (still no arithmetic on secret values).
local function UpdateCastTimes()
    if not overlay or not overlay._casting then return end
    local duration
    if overlay._channel then
        duration = overlay._empowered and UnitEmpoweredChannelDuration("target")
            or UnitChannelDuration("target")
    else
        duration = UnitCastingDuration("target")
    end
    if duration then
        overlay:SetTimerDuration(duration, SMOOTHING, overlay._direction)
    end
end

local function UpdateInterruptible(notInterruptible)
    if not overlay then return end
    overlay._notInterruptible = notInterruptible
    RefreshOverlayIcon()
end

local function OnDriverEvent(_, event, unit, ...)
    if event == "PLAYER_TARGET_CHANGED" then
        EvaluateCast()
        return
    end
    if unit ~= "target" then return end
    if event == "UNIT_SPELLCAST_START"
        or event == "UNIT_SPELLCAST_CHANNEL_START"
        or event == "UNIT_SPELLCAST_EMPOWER_START" then
        EvaluateCast()
    elseif event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_EMPOWER_STOP"
        or event == "UNIT_SPELLCAST_INTERRUPTED"
        or event == "UNIT_SPELLCAST_FAILED" then
        HideCast()
    elseif event == "UNIT_SPELLCAST_DELAYED"
        or event == "UNIT_SPELLCAST_CHANNEL_UPDATE"
        or event == "UNIT_SPELLCAST_EMPOWER_UPDATE" then
        UpdateCastTimes()
    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE" then
        UpdateInterruptible(false)
    elseif event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        UpdateInterruptible(true)
    end
end

local DRIVER_UNIT_EVENTS = {
    "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP",
    "UNIT_SPELLCAST_EMPOWER_START", "UNIT_SPELLCAST_EMPOWER_STOP",
    "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_EMPOWER_UPDATE",
    "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_INTERRUPTIBLE", "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
}

local function RegisterDriverEvents()
    local d = overlay and overlay._driver
    if not d then return end
    d:SetScript("OnEvent", OnDriverEvent)
    for _, ev in ipairs(DRIVER_UNIT_EVENTS) do
        d:RegisterUnitEvent(ev, "target")
    end
    d:RegisterEvent("PLAYER_TARGET_CHANGED")
end

local function UnregisterDriverEvents()
    local d = overlay and overlay._driver
    if d then d:UnregisterAllEvents() end
end

local function ActivateOverlay()
    if not ResolveFrames() then return end
    if not EnsureOverlay() then return end

    -- Re-asserted on every apply so a parent reload that re-enabled the element
    -- or restored its background can't leak the original bar through the overlay.
    if targetFrame.IsElementEnabled and targetFrame:IsElementEnabled("Castbar") then
        targetFrame:DisableElement("Castbar")
    end
    -- SetAlpha(0) (not Hide) because the parent Show()s castbarBg from several
    -- code paths; alpha survives Show/Hide and keeps the whole subtree invisible.
    if parentCastbarBg then parentCastbarBg:SetAlpha(0) end
    parentDisabled = true

    RefreshOverlayText()
    RefreshOverlayIcon()
    LayoutOverlay()
    RegisterDriverEvents()
    EvaluateCast() -- show immediately if the target is already casting
end

local function DeactivateOverlay()
    UnregisterDriverEvents()
    HideCast()

    if parentDisabled and targetFrame then
        if parentCastbarBg then parentCastbarBg:SetAlpha(1) end
        if targetFrame.IsElementEnabled and not targetFrame:IsElementEnabled("Castbar")
            and targetFrame.EnableElement then
            targetFrame:EnableElement("Castbar")
            if parentCastbar and parentCastbar.ForceUpdate then
                parentCastbar:ForceUpdate()
            end
        end
        parentDisabled = false
    end
end

-------------------------------------------------------------------------------
--  OVERLAY OFF: decorate the PARENT castbar's icon (event-driven, no driver)
-------------------------------------------------------------------------------
local function EnsureParentIconFS()
    local iconFrame = parentCastbar and parentCastbar._iconFrame
    if not iconFrame then return nil end
    if pIconFS and pIconFS:GetParent() == iconFrame then return pIconFS end
    pIconFS = iconFrame:CreateFontString(nil, "OVERLAY")
    pIconFS:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
    pIconFS:Hide()
    return pIconFS
end

local function ApplyParentIconLayout()
    local cfg = DB()
    local iconFrame = parentCastbar and parentCastbar._iconFrame
    if not cfg or not iconFrame then return end

    if not pOrigIconPoint then
        local point, relTo, relPoint, x, y = iconFrame:GetPoint(1)
        pOrigIconPoint = { point = point, relTo = relTo, relPoint = relPoint, x = x, y = y }
        pOrigIconSize = { width = iconFrame:GetWidth(), height = iconFrame:GetHeight() }
    end

    iconFrame:SetSize(cfg.iconSize or 32, cfg.iconSize or 32)
    iconFrame:ClearAllPoints()
    if cfg.detachIcon then
        local pair = ANCHOR_MAP[cfg.detachAnchor] or ANCHOR_MAP.RIGHT
        iconFrame:SetPoint(pair[1], parentCastbar, pair[2], cfg.detachXOffset or 0, cfg.detachYOffset or 0)
    elseif pOrigIconPoint and pOrigIconPoint.point then
        iconFrame:SetPoint(pOrigIconPoint.point, pOrigIconPoint.relTo, pOrigIconPoint.relPoint,
            pOrigIconPoint.x, pOrigIconPoint.y)
    end

    local PP = EllesmereUI and EllesmereUI.PP
    if PP and PP.SetBorderSize then PP.SetBorderSize(iconFrame, cfg.iconBorderWidth or 1) end
end

local function ApplyParentInterruptibleVisual()
    local cfg = DB()
    if not cfg or not parentCastbar then return end
    local icon = parentCastbar.Icon
    local unint = parentCastbar.notInterruptible

    if icon then
        if cfg.desaturateUninterruptible and unint ~= nil then
            icon:SetDesaturated(unint)
        else
            icon:SetDesaturated(false)
        end
    end

    local fs = EnsureParentIconFS()
    if fs then
        local fontKey = cfg.uninterruptibleTextFont or "__global"
        local fontPath
        if fontKey == "__global" then
            fontPath = (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
        else
            fontPath = (EllesmereUI.ResolveFontName and EllesmereUI.ResolveFontName(fontKey)) or "Fonts\\FRIZQT__.TTF"
        end
        fs:SetFont(fontPath, cfg.uninterruptibleTextSize or 12, "OUTLINE")
        fs:SetTextColor(cfg.uninterruptibleTextR or 1, cfg.uninterruptibleTextG or 0.2, cfg.uninterruptibleTextB or 0.2, 1)
        fs:SetText(cfg.uninterruptibleText or "X")
        -- unint may be a secret boolean; drive visibility via SetAlphaFromBoolean
        -- rather than boolean arithmetic (see RefreshOverlayIcon).
        fs:SetShown(cfg.showUninterruptibleText and true or false)
        if cfg.showUninterruptibleText and unint ~= nil and fs.SetAlphaFromBoolean then
            fs:SetAlphaFromBoolean(unint, 1, 0)
        else
            fs:SetAlpha(cfg.showUninterruptibleText and 1 or 0)
        end
    end
end

local function ApplyParentIconDecoration()
    ApplyParentIconLayout()
    ApplyParentInterruptibleVisual()
end

-- Wrap (never replace) an existing Post* field so parent behaviour survives.
local function EnsureWrappedField(obj, field, extra)
    obj._evlWrappers = obj._evlWrappers or {}
    local state = obj._evlWrappers[field]
    if not state then
        state = {}
        state.fn = function(self, ...)
            if state.orig then state.orig(self, ...) end
            if not (DB() and DB().overlayMode) then extra(self, ...) end
        end
        obj._evlWrappers[field] = state
    end
    if obj[field] ~= state.fn then
        state.orig = obj[field]
        obj[field] = state.fn
    end
end

InstallHooks = function()
    if not ResolveFrames() or not parentCastbar then return end
    EnsureWrappedField(parentCastbar, "PostCastStart", ApplyParentIconDecoration)
    EnsureWrappedField(parentCastbar, "PostChannelStart", ApplyParentIconDecoration)
    EnsureWrappedField(parentCastbar, "PostCastInterruptible", ApplyParentInterruptibleVisual)
    local function stopCleanup()
        if pIconFS then pIconFS:Hide() end
        if parentCastbar.Icon then parentCastbar.Icon:SetDesaturated(false) end
    end
    EnsureWrappedField(parentCastbar, "PostCastStop", stopCleanup)
    EnsureWrappedField(parentCastbar, "PostChannelStop", stopCleanup)
    EnsureWrappedField(parentCastbar, "PostCastInterrupted", stopCleanup)
    EnsureWrappedField(parentCastbar, "PostCastFail", stopCleanup)
end

-------------------------------------------------------------------------------
--  Apply (called on settings change / login)
-------------------------------------------------------------------------------
local function ApplyAll()
    if not ResolveFrames() then return end
    InstallHooks()

    local cfg = DB()
    if not cfg or not cfg.enabled then
        DeactivateOverlay()
        return
    end

    if cfg.overlayMode then
        ActivateOverlay()
    else
        DeactivateOverlay()
        ApplyParentIconDecoration()
    end
end
EVL.ApplyCastbar = ApplyAll

-------------------------------------------------------------------------------
--  Bootstrap: wait for EllesmereUIUnitFrames_Target to exist (hard TOC
--  dependency guarantees load order, but the frame is built inside that addon's
--  own PLAYER_LOGIN handler, so a short poll avoids a race).
-------------------------------------------------------------------------------
local attempts = 0
local function TryInit()
    attempts = attempts + 1
    if not ResolveFrames() or not parentCastbar then
        if attempts < 30 then
            C_Timer.After(0.2, TryInit)
        end
        return
    end
    InstallHooks()
    ApplyAll()
end

function EVL.InitCastbarHooks()
    TryInit()
end
