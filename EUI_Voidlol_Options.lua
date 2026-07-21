-------------------------------------------------------------------------------
--  EUI_Voidlol_Options.lua
--  Registers the Voidlol module with EllesmereUI's options panel. Three pages:
--    Quick Focus    -- Modifier+Click on a unit frame to set focus
--    Combat Text    -- Incoming Damage / Incoming Heal frames
--    Target Castbar -- modifications to EllesmereUI's target castbar
--  All get/set calls go through the global bridge to the addon's DB profile.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EVL = ns.EVL

-- Reads the .toc's ## Version line (the release workflow rewrites it on every
-- publish), so this always matches whatever actually shipped -- no separate
-- constant to keep in sync by hand.
local function GetAddonVersion()
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        return C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
    end
    if GetAddOnMetadata then
        return GetAddOnMetadata(ADDON_NAME, "Version")
    end
end

local PAGE_QOL              = "QoL"
local PAGE_TWEAKS           = "Tweaks"
local PAGE_QUICK_FOCUS      = "Quick Focus"
local PAGE_COMBAT_TEXT      = "Combat Text"
local PAGE_CASTBAR          = "Target Castbar"
local PAGE_HEALER_MANA      = "Healer Mana"
local PAGE_INTERRUPT_TRACKER = "Interrupt Tracker"

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")

    if not EllesmereUI or not EllesmereUI.Widgets then return end

    ---------------------------------------------------------------------------
    --  DB helpers
    ---------------------------------------------------------------------------
    local function DB()      return EVL.DB() end
    local function QoL()     local d = DB(); return d and d.qol end
    local function SB()      local q = QoL(); return q and q.statusBar end
    local function SBBlock(key) local s = SB(); local b = s and s.blocks; return b and b[key] end
    local function QF()      local d = DB(); return d and d.quickFocus end
    local function CT(key)   local d = DB(); local ct = d and d.combatText; return ct and ct[key] end
    local function Castbar() local d = DB(); return d and d.castbar end
    local function HealerMana() local d = DB(); return d and d.healerMana end
    local function HMFrame(key) local h = HealerMana(); return h and h[key] end
    local function IT() local d = DB(); return d and d.interruptTracker end

    -- "Blizzard" default + every registered LibSharedMedia statusbar texture.
    local function BuildBarTextureDropdownData()
        local values = { Blizzard = "Blizzard (Default)" }
        local order  = { "Blizzard" }
        if EllesmereUI.AppendSharedMediaTextures then
            local names, texOrder, textures = {}, {}, {}
            EllesmereUI.AppendSharedMediaTextures(names, texOrder, nil, textures)
            for _, key in ipairs(texOrder) do
                if key ~= "---" then
                    values[key] = names[key] or key
                    order[#order + 1] = key
                end
            end
        end
        return values, order
    end
    local castbarPreview
    local castbarPreviewHdr
    local castbarHeaderBuilder
    local healerManaPreviewHdr
    local healerManaPartyCaption, healerManaRaidCaption
    local healerManaHeaderBuilder
    local interruptTrackerPreviewHdr
    local interruptTrackerHeaderBuilder
    -- Click-navigation state for the IT preview (hover a sub-part, click to
    -- scroll to + flash its settings row). interruptTrackerClickTargets is
    -- set once BuildInterruptTrackerPage has captured its section/row
    -- widgets; interruptTrackerOverlaysBuilt guards against attaching twice.
    -- See AttachInterruptTrackerPreviewOverlays below.
    local interruptTrackerClickTargets
    local interruptTrackerOverlaysBuilt = false
    -- Same click-navigation state, for the Healer Mana preview (party/raid
    -- sample rows). See AttachHealerManaPreviewOverlays below.
    local healerManaClickTargets
    local healerManaOverlaysBuilt = false
    -- Same click-navigation state, for the Target Castbar preview (reused
    -- Unit Frames target preview). See AttachCastbarPreviewOverlays below.
    -- (No page-level "already built" flag here -- tracked per preview
    -- object instead, since that object gets rebuilt fresh each redraw.)
    local castbarClickTargets
    -- Which page's header-preview currently owns the shared content-header
    -- frame. HealerMana/InterruptTracker/Castbar all reparent their sample
    -- bars into that one recycled `hdr` object via their own cached
    -- ...PreviewHdr locals, which never get cleared on page switch -- without
    -- this guard, RefreshAll() (fired on every settings change, regardless
    -- of which page is open) happily re-shows a DIFFERENT page's stale
    -- preview into the currently visible header.
    local activePreviewPage

    local RefreshWidgets
    local ANCHOR_MAP = {
        RIGHT  = { "LEFT",   "RIGHT"  },
        LEFT   = { "RIGHT",  "LEFT"   },
        TOP    = { "BOTTOM", "TOP"    },
        BOTTOM = { "TOP",    "BOTTOM" },
    }

    local function GetCastbarPreviewTarget(hdr)
        local children = { hdr:GetChildren() }
        for i = 1, #children do
            local child = children[i]
            if child and child._previewScale and child._castbar and child._barArea then
                return child
            end
        end
    end

    local function HideHeaderPreviewDropdown(hdr, keep)
        local children = { hdr:GetChildren() }
        for i = 1, #children do
            local child = children[i]
            if child ~= keep then
                child:Hide()
            end
        end
    end

    local function EnsurePreviewSpark(castbar)
        if castbar._evlPreviewSpark then
            return castbar._evlPreviewSpark
        end
        local spark = castbar:CreateTexture(nil, "OVERLAY", nil, 7)
        spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
        spark:SetBlendMode("ADD")
        spark:SetVertexColor(1, 1, 1, 1)
        spark:SetAlpha(0.95)
        spark:SetSize(24, 24)
        castbar._evlPreviewSpark = spark
        return spark
    end

    local function EnsurePreviewUninterruptibleFS(iconFrame)
        if iconFrame._evlUninterruptibleFS then
            return iconFrame._evlUninterruptibleFS
        end
        local fs = iconFrame:CreateFontString(nil, "OVERLAY")
        fs:SetPoint("CENTER", iconFrame, "CENTER", 0, 0)
        iconFrame._evlUninterruptibleFS = fs
        return fs
    end

    local function GetPreviewCastFill(castbar)
        local regions = { castbar:GetRegions() }
        for i = 1, #regions do
            local region = regions[i]
            if region
                and region ~= castbar._previewBgTex
                and region ~= castbar._evlPreviewSpark
                and region.GetObjectType
                and region:GetObjectType() == "Texture"
                and region.GetDrawLayer
            then
                local layer = region:GetDrawLayer()
                if layer == "ARTWORK" then
                    return region
                end
            end
        end
    end

    local function ApplyCastbarPreviewStyle(preview)
        if not preview or not preview._castbar or not preview._barArea then return end

        local cfg = Castbar()
        local castbar = preview._castbar
        local castFill = GetPreviewCastFill(castbar)
        local iconFrame = preview._castIconFrame
        local PP = EllesmereUI and EllesmereUI.PP
        local fontPath

        if not cfg then return end

        if not preview._evlOrigCastbar then
            local cbPoint, cbRelTo, cbRelPoint, cbX, cbY = castbar:GetPoint(1)
            preview._evlOrigCastbar = {
                point = cbPoint, relTo = cbRelTo, relPoint = cbRelPoint, x = cbX, y = cbY,
                width = castbar:GetWidth(), height = castbar:GetHeight(),
            }
        end
        if iconFrame and not preview._evlOrigIcon then
            local ip, irt, irp, ix, iy = iconFrame:GetPoint(1)
            preview._evlOrigIcon = {
                point = ip, relTo = irt, relPoint = irp, x = ix, y = iy,
                width = iconFrame:GetWidth(), height = iconFrame:GetHeight(),
            }
        end

        if cfg.overlayMode then
            castbar:ClearAllPoints()
            castbar:SetAllPoints(preview._barArea)
            castbar:SetFrameLevel(preview:GetFrameLevel() + 20)
            if castbar._previewBgTex then castbar._previewBgTex:SetAlpha(0) end
            if preview._castbar._border and preview._castbar._border.Hide then
                preview._castbar._border:Hide()
            end
            if PP and PP.HideBorder then PP.HideBorder(castbar) end
        else
            local orig = preview._evlOrigCastbar
            if orig and orig.point then
                castbar:ClearAllPoints()
                castbar:SetPoint(orig.point, orig.relTo, orig.relPoint, orig.x, orig.y)
                castbar:SetSize(orig.width, orig.height)
            end
            if castbar._previewBgTex then castbar._previewBgTex:SetAlpha(1) end
            if PP and PP.ShowBorder then PP.ShowBorder(castbar) end
        end

        if castFill then
            castFill:SetAlpha(cfg.overlayMode and 0 or 1)
        end

        -- The live overlay bar shows only spell name (left) + time (right) +
        -- spark, so hide the parent bar's cast-target zone in overlay mode
        -- while preserving the user's normal target-text preference otherwise.
        if castbar.Target then
            if preview._evlTargetWasShown == nil then
                preview._evlTargetWasShown = castbar.Target:IsShown()
            end
            castbar.Target:SetShown(not cfg.overlayMode and preview._evlTargetWasShown)
        end

        if iconFrame then
            local iconSize = cfg.iconSize or 32
            iconFrame:SetSize(iconSize, iconSize)
            iconFrame:ClearAllPoints()
            if cfg.detachIcon then
                local pair = ANCHOR_MAP[cfg.detachAnchor] or ANCHOR_MAP.RIGHT
                iconFrame:SetPoint(pair[1], castbar, pair[2], cfg.detachXOffset or 0, cfg.detachYOffset or 0)
            elseif cfg.overlayMode then
                -- Non-detached default in overlay mode: right, outside the bar
                -- (mirrors the live standalone overlay castbar).
                local pair = ANCHOR_MAP.RIGHT
                iconFrame:SetPoint(pair[1], castbar, pair[2], 0, 0)
            else
                local orig = preview._evlOrigIcon
                if orig and orig.point then
                    iconFrame:SetPoint(orig.point, orig.relTo, orig.relPoint, orig.x, orig.y)
                    iconFrame:SetSize(orig.width, orig.height)
                end
            end
            if PP and PP.SetBorderSize then
                PP.SetBorderSize(iconFrame, cfg.iconBorderWidth or 1)
            end
            if iconFrame._iconTex and iconFrame._iconTex.SetDesaturated then
                iconFrame._iconTex:SetDesaturated(cfg.desaturateUninterruptible == true)
            end

            local fs = EnsurePreviewUninterruptibleFS(iconFrame)
            if cfg.uninterruptibleTextFont == "__global" then
                fontPath = (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
            else
                fontPath = (EllesmereUI.ResolveFontName and EllesmereUI.ResolveFontName(cfg.uninterruptibleTextFont or "__global")) or "Fonts\\FRIZQT__.TTF"
            end
            fs:SetFont(fontPath, cfg.uninterruptibleTextSize or 12, "OUTLINE")
            fs:SetTextColor(cfg.uninterruptibleTextR or 1, cfg.uninterruptibleTextG or 0.2, cfg.uninterruptibleTextB or 0.2, 1)
            fs:SetText(cfg.uninterruptibleText or "!")
            fs:SetShown(cfg.showUninterruptibleText == true)
        end

        local spark = EnsurePreviewSpark(castbar)
        if cfg.overlayMode then
            local anchor = castFill or castbar
            spark:ClearAllPoints()
            spark:SetPoint("CENTER", anchor, "RIGHT", 0, 0)
            spark:SetSize(24, math.max(14, preview._barArea:GetHeight() * 1.35))
            spark:Show()
        else
            spark:Hide()
        end
    end

    -- Restyles BOTH standalone Healer Mana preview groups -- Party (1 row)
    -- and Raid (4 rows) -- side by side, independent of the Enabled toggle /
    -- Unlock Mode / which group you're actually in, so the options page
    -- always shows live samples for both frames' own settings at once.
    -- Also re-parents/re-shows on every call: reported symptom was the
    -- preview vanishing after leaving a dungeon group (i.e. after a loading
    -- screen) until /reloadui -- a PLAYER_ENTERING_WORLD-driven refresh below
    -- is the standard remedy for a dynamically-created frame going stale
    -- across a loading screen, and re-parenting fixes a stale "parent" from
    -- an earlier header rebuild the same way the header builder itself does.
    local HEALER_MANA_PARTY_COUNT = 1
    local HEALER_MANA_RAID_COUNT  = 4

    -- CLICK NAVIGATION for the Healer Mana preview (party/raid sample rows)
    -- -- same pattern as the Interrupt Tracker preview above (and
    -- EllesmereUIUnitFrames' preview, which this was originally copied from).
    local hmGlowFrame
    local function PlayHealerManaGlow(targetFrame)
        if not targetFrame then return end
        if not hmGlowFrame then
            hmGlowFrame = CreateFrame("Frame")
            local c = EllesmereUI.ELLESMERE_GREEN
            local function MkEdge()
                local t = hmGlowFrame:CreateTexture(nil, "OVERLAY", nil, 7)
                t:SetColorTexture(c.r, c.g, c.b, 1)
                return t
            end
            hmGlowFrame._top = MkEdge()
            hmGlowFrame._bot = MkEdge()
            hmGlowFrame._lft = MkEdge()
            hmGlowFrame._rgt = MkEdge()
            hmGlowFrame._top:SetHeight(2)
            hmGlowFrame._top:SetPoint("TOPLEFT"); hmGlowFrame._top:SetPoint("TOPRIGHT")
            hmGlowFrame._bot:SetHeight(2)
            hmGlowFrame._bot:SetPoint("BOTTOMLEFT"); hmGlowFrame._bot:SetPoint("BOTTOMRIGHT")
            hmGlowFrame._lft:SetWidth(2)
            hmGlowFrame._lft:SetPoint("TOPLEFT", hmGlowFrame._top, "BOTTOMLEFT")
            hmGlowFrame._lft:SetPoint("BOTTOMLEFT", hmGlowFrame._bot, "TOPLEFT")
            hmGlowFrame._rgt:SetWidth(2)
            hmGlowFrame._rgt:SetPoint("TOPRIGHT", hmGlowFrame._top, "BOTTOMRIGHT")
            hmGlowFrame._rgt:SetPoint("BOTTOMRIGHT", hmGlowFrame._bot, "TOPRIGHT")
        end
        hmGlowFrame:SetParent(targetFrame)
        hmGlowFrame:SetAllPoints(targetFrame)
        hmGlowFrame:SetFrameLevel(targetFrame:GetFrameLevel() + 5)
        hmGlowFrame:SetAlpha(1)
        hmGlowFrame:Show()
        local elapsed = 0
        hmGlowFrame:SetScript("OnUpdate", function(self, dt)
            elapsed = elapsed + dt
            if elapsed >= 0.75 then
                self:Hide(); self:SetScript("OnUpdate", nil); return
            end
            self:SetAlpha(1 - elapsed / 0.75)
        end)
    end

    local function NavigateToHealerManaSetting(key)
        local m = healerManaClickTargets and healerManaClickTargets[key]
        if not m or not m.section or not m.target then return end
        local sf = EllesmereUI._scrollFrame
        if not sf then return end
        local _, _, _, _, headerY = m.section:GetPoint(1)
        if not headerY then return end
        local scrollPos = math.max(0, math.abs(headerY) - 40)
        EllesmereUI.SmoothScrollTo(scrollPos)
        local glowTarget = m.target
        if m.slotSide then
            local region = (m.slotSide == "left") and m.target._leftRegion or m.target._rightRegion
            if region then glowTarget = region end
        end
        C_Timer.After(0.15, function() PlayHealerManaGlow(glowTarget) end)
    end

    local function CreateHealerManaHitOverlay(element, mappingKey, isText, frameLevelOverride)
        local anchor = isText and element:GetParent() or element
        if not anchor.CreateTexture then anchor = anchor:GetParent() end
        local btn = CreateFrame("Button", nil, anchor)
        if isText then
            local function ResizeToText()
                local ok, tw, th = pcall(function()
                    local w = element:GetStringWidth() or 0
                    local hh = element:GetStringHeight() or 0
                    if w < 4 then w = 4 end
                    if hh < 4 then hh = 4 end
                    return w, hh
                end)
                if not ok then tw = 40; th = 12 end
                btn:SetSize(tw + 4, th + 4)
            end
            ResizeToText()
            local justify = element:GetJustifyH()
            if justify == "RIGHT" then btn:SetPoint("RIGHT", element, "RIGHT", 2, 0)
            elseif justify == "CENTER" then btn:SetPoint("CENTER", element, "CENTER", 0, 0)
            else btn:SetPoint("LEFT", element, "LEFT", -2, 0) end
            btn:SetScript("OnShow", function() ResizeToText() end)
        else
            btn:SetAllPoints(element)
        end
        btn:SetFrameLevel(frameLevelOverride or (anchor:GetFrameLevel() + 20))
        btn:RegisterForClicks("LeftButtonDown")
        local c = EllesmereUI.ELLESMERE_GREEN
        local brd = EllesmereUI.PP.CreateBorder(btn, c.r, c.g, c.b, 1, 2, "OVERLAY", 7)
        brd:Hide()
        btn:SetScript("OnEnter", function() brd:Show() end)
        btn:SetScript("OnLeave", function() brd:Hide() end)
        btn:SetScript("OnMouseDown", function() NavigateToHealerManaSetting(mappingKey) end)
        return btn
    end

    -- Attaches hit overlays to every party/raid preview row, once BOTH the
    -- click-target mapping (built by BuildHealerManaPage) and the preview
    -- rows (built by RefreshHealerManaPreview) exist. Raid's rows all share
    -- the same "raid_*" keys since one setting applies to all of them.
    local function AttachHealerManaPreviewOverlays()
        if healerManaOverlaysBuilt then return end
        if not healerManaClickTargets then return end
        if not EVL.HealerMana_GetPreviewRows then return end
        local partyRows = EVL.HealerMana_GetPreviewRows("party")
        local raidRows = EVL.HealerMana_GetPreviewRows("raid")
        if not (partyRows and partyRows[1] and raidRows and raidRows[HEALER_MANA_RAID_COUNT]) then return end
        healerManaOverlaysBuilt = true

        local function AttachRow(row, prefix)
            local lvl = row:GetFrameLevel() + 20
            if row.iconFrame then CreateHealerManaHitOverlay(row.iconFrame, prefix .. "_icon", false, lvl) end
            if row.nameFS then CreateHealerManaHitOverlay(row.nameFS, prefix .. "_name", true, lvl + 5) end
            if row.manaFS then CreateHealerManaHitOverlay(row.manaFS, prefix .. "_mana", true, lvl + 5) end
        end

        for _, row in ipairs(partyRows) do AttachRow(row, "party") end
        for _, row in ipairs(raidRows) do AttachRow(row, "raid") end
    end

    local function RefreshHealerManaPreview()
        if activePreviewPage ~= PAGE_HEALER_MANA then return end
        if not healerManaPreviewHdr then return end
        if not (EVL.HealerMana_EnsurePreviewGroup and EVL.HealerMana_RefreshPreviewGroup) then return end
        local hdr = healerManaPreviewHdr

        local partyFrame = EVL.HealerMana_EnsurePreviewGroup("party", hdr, HEALER_MANA_PARTY_COUNT)
        local raidFrame  = EVL.HealerMana_EnsurePreviewGroup("raid", hdr, HEALER_MANA_RAID_COUNT)

        if not healerManaPartyCaption then
            healerManaPartyCaption = hdr:CreateFontString(nil, "OVERLAY")
            local fontPath = (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
            healerManaPartyCaption:SetFont(fontPath, 11, "OUTLINE")
            healerManaPartyCaption:SetTextColor(1, 1, 1, 0.6)
            healerManaPartyCaption:SetText("PARTY")
        end
        if not healerManaRaidCaption then
            healerManaRaidCaption = hdr:CreateFontString(nil, "OVERLAY")
            local fontPath = (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
            healerManaRaidCaption:SetFont(fontPath, 11, "OUTLINE")
            healerManaRaidCaption:SetTextColor(1, 1, 1, 0.6)
            healerManaRaidCaption:SetText("RAID")
        end
        healerManaPartyCaption:SetParent(hdr)
        healerManaRaidCaption:SetParent(hdr)

        local pw, ph = EVL.HealerMana_RefreshPreviewGroup("party", HEALER_MANA_PARTY_COUNT)
        local rw, rh = EVL.HealerMana_RefreshPreviewGroup("raid", HEALER_MANA_RAID_COUNT)

        local CAPTION_GAP, COLUMN_GAP, TOP_PAD = 4, 40, 4
        local totalW = pw + COLUMN_GAP + rw
        local startX = -totalW / 2

        healerManaPartyCaption:ClearAllPoints()
        healerManaPartyCaption:SetPoint("TOPLEFT", hdr, "TOP", startX, -TOP_PAD)
        partyFrame:ClearAllPoints()
        partyFrame:SetPoint("TOPLEFT", healerManaPartyCaption, "BOTTOMLEFT", 0, -CAPTION_GAP)
        partyFrame:Show()

        healerManaRaidCaption:ClearAllPoints()
        healerManaRaidCaption:SetPoint("TOPLEFT", hdr, "TOP", startX + pw + COLUMN_GAP, -TOP_PAD)
        raidFrame:ClearAllPoints()
        raidFrame:SetPoint("TOPLEFT", healerManaRaidCaption, "BOTTOMLEFT", 0, -CAPTION_GAP)
        raidFrame:Show()

        local captionH = healerManaPartyCaption:GetStringHeight() or 12
        AttachHealerManaPreviewOverlays()
        return TOP_PAD + captionH + CAPTION_GAP + math.max(ph, rh) + 10
    end

    local healerManaPreviewHealFrame = CreateFrame("Frame")
    healerManaPreviewHealFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    healerManaPreviewHealFrame:SetScript("OnEvent", RefreshHealerManaPreview)

    -- CLICK NAVIGATION for the IT preview -- hover a sub-part to highlight
    -- it, click to scroll to and flash its settings row. Same pattern
    -- EllesmereUIUnitFrames' preview uses (CreateHitOverlay / NavigateToSetting
    -- / PlaySettingGlow); reimplemented here since that system is local to
    -- that addon's options file, not exported.
    local itGlowFrame
    local function PlayInterruptTrackerGlow(targetFrame)
        if not targetFrame then return end
        if not itGlowFrame then
            itGlowFrame = CreateFrame("Frame")
            local c = EllesmereUI.ELLESMERE_GREEN
            local function MkEdge()
                local t = itGlowFrame:CreateTexture(nil, "OVERLAY", nil, 7)
                t:SetColorTexture(c.r, c.g, c.b, 1)
                return t
            end
            itGlowFrame._top = MkEdge()
            itGlowFrame._bot = MkEdge()
            itGlowFrame._lft = MkEdge()
            itGlowFrame._rgt = MkEdge()
            itGlowFrame._top:SetHeight(2)
            itGlowFrame._top:SetPoint("TOPLEFT"); itGlowFrame._top:SetPoint("TOPRIGHT")
            itGlowFrame._bot:SetHeight(2)
            itGlowFrame._bot:SetPoint("BOTTOMLEFT"); itGlowFrame._bot:SetPoint("BOTTOMRIGHT")
            itGlowFrame._lft:SetWidth(2)
            itGlowFrame._lft:SetPoint("TOPLEFT", itGlowFrame._top, "BOTTOMLEFT")
            itGlowFrame._lft:SetPoint("BOTTOMLEFT", itGlowFrame._bot, "TOPLEFT")
            itGlowFrame._rgt:SetWidth(2)
            itGlowFrame._rgt:SetPoint("TOPRIGHT", itGlowFrame._top, "BOTTOMRIGHT")
            itGlowFrame._rgt:SetPoint("BOTTOMRIGHT", itGlowFrame._bot, "TOPRIGHT")
        end
        itGlowFrame:SetParent(targetFrame)
        itGlowFrame:SetAllPoints(targetFrame)
        itGlowFrame:SetFrameLevel(targetFrame:GetFrameLevel() + 5)
        itGlowFrame:SetAlpha(1)
        itGlowFrame:Show()
        local elapsed = 0
        itGlowFrame:SetScript("OnUpdate", function(self, dt)
            elapsed = elapsed + dt
            if elapsed >= 0.75 then
                self:Hide(); self:SetScript("OnUpdate", nil); return
            end
            self:SetAlpha(1 - elapsed / 0.75)
        end)
    end

    local function NavigateToInterruptTrackerSetting(key)
        local m = interruptTrackerClickTargets and interruptTrackerClickTargets[key]
        if not m or not m.section or not m.target then return end
        local sf = EllesmereUI._scrollFrame
        if not sf then return end
        local _, _, _, _, headerY = m.section:GetPoint(1)
        if not headerY then return end
        local scrollPos = math.max(0, math.abs(headerY) - 40)
        EllesmereUI.SmoothScrollTo(scrollPos)
        local glowTarget = m.target
        if m.slotSide then
            local region = (m.slotSide == "left") and m.target._leftRegion or m.target._rightRegion
            if region then glowTarget = region end
        end
        C_Timer.After(0.15, function() PlayInterruptTrackerGlow(glowTarget) end)
    end

    -- Hit overlay factory: an invisible button over `element` that
    -- highlights on hover and navigates on click. Text elements size
    -- themselves to the actual rendered text (not the whole row) via
    -- GetStringWidth/Height.
    local function CreateInterruptTrackerHitOverlay(element, mappingKey, isText, frameLevelOverride)
        local anchor = isText and element:GetParent() or element
        if not anchor.CreateTexture then anchor = anchor:GetParent() end
        local btn = CreateFrame("Button", nil, anchor)
        if isText then
            local function ResizeToText()
                local ok, tw, th = pcall(function()
                    local w = element:GetStringWidth() or 0
                    local hh = element:GetStringHeight() or 0
                    if w < 4 then w = 4 end
                    if hh < 4 then hh = 4 end
                    return w, hh
                end)
                if not ok then tw = 40; th = 12 end
                btn:SetSize(tw + 4, th + 4)
            end
            ResizeToText()
            local justify = element:GetJustifyH()
            if justify == "RIGHT" then btn:SetPoint("RIGHT", element, "RIGHT", 2, 0)
            elseif justify == "CENTER" then btn:SetPoint("CENTER", element, "CENTER", 0, 0)
            else btn:SetPoint("LEFT", element, "LEFT", -2, 0) end
            btn:SetScript("OnShow", function() ResizeToText() end)
        else
            btn:SetAllPoints(element)
        end
        btn:SetFrameLevel(frameLevelOverride or (anchor:GetFrameLevel() + 20))
        btn:RegisterForClicks("LeftButtonDown")
        local c = EllesmereUI.ELLESMERE_GREEN
        local brd = EllesmereUI.PP.CreateBorder(btn, c.r, c.g, c.b, 1, 2, "OVERLAY", 7)
        brd:Hide()
        btn:SetScript("OnEnter", function() brd:Show() end)
        btn:SetScript("OnLeave", function() brd:Hide() end)
        btn:SetScript("OnMouseDown", function() NavigateToInterruptTrackerSetting(mappingKey) end)
        return btn
    end

    -- Attaches hit overlays to the preview's two sample bars, once BOTH the
    -- click-target mapping (built by BuildInterruptTrackerPage) and the
    -- preview bars (built by RefreshInterruptTrackerPreview) exist -- called
    -- from both places, since which one runs first isn't guaranteed.
    local function AttachInterruptTrackerPreviewOverlays()
        if interruptTrackerOverlaysBuilt then return end
        if not interruptTrackerClickTargets then return end
        local previewBars = EVL.InterruptTracker_GetPreviewBars and EVL.InterruptTracker_GetPreviewBars()
        if not (previewBars and previewBars[1] and previewBars[2]) then return end
        interruptTrackerOverlaysBuilt = true

        local readyBar, cooldownBar = previewBars[1], previewBars[2]
        local readyLvl = readyBar:GetFrameLevel() + 20
        CreateInterruptTrackerHitOverlay(readyBar, "readyBar", false, readyLvl)
        if readyBar.icon then CreateInterruptTrackerHitOverlay(readyBar.icon, "icon", false, readyLvl) end
        if readyBar.nameText then CreateInterruptTrackerHitOverlay(readyBar.nameText, "nameTextReady", true, readyLvl + 5) end
        if readyBar.timeText then CreateInterruptTrackerHitOverlay(readyBar.timeText, "timeTextReady", true, readyLvl + 5) end

        local cdLvl = cooldownBar:GetFrameLevel() + 20
        CreateInterruptTrackerHitOverlay(cooldownBar, "cooldownBar", false, cdLvl)
        if cooldownBar.icon then CreateInterruptTrackerHitOverlay(cooldownBar.icon, "icon", false, cdLvl) end
        if cooldownBar.nameText then CreateInterruptTrackerHitOverlay(cooldownBar.nameText, "nameTextCooldown", true, cdLvl + 5) end
        if cooldownBar.timeText then CreateInterruptTrackerHitOverlay(cooldownBar.timeText, "timeText", true, cdLvl + 5) end
    end

    -- Two standalone sample bars (one ready, one on cooldown with a
    -- randomized hit/miss badge), independent of Enabled/group status, so
    -- the options page always shows a live preview of the current settings.
    local function RefreshInterruptTrackerPreview()
        if activePreviewPage ~= PAGE_INTERRUPT_TRACKER then return end
        if not interruptTrackerPreviewHdr then return end
        if not (EVL.InterruptTracker_EnsurePreviewGroup and EVL.InterruptTracker_RefreshPreviewGroup) then return end
        local hdr = interruptTrackerPreviewHdr

        local frame = EVL.InterruptTracker_EnsurePreviewGroup(hdr)
        local _, h = EVL.InterruptTracker_RefreshPreviewGroup()

        frame:ClearAllPoints()
        frame:SetPoint("TOP", hdr, "TOP", 0, -8)
        frame:Show()
        AttachInterruptTrackerPreviewOverlays()

        return h + 16
    end

    local interruptTrackerPreviewHealFrame = CreateFrame("Frame")
    interruptTrackerPreviewHealFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    interruptTrackerPreviewHealFrame:SetScript("OnEvent", RefreshInterruptTrackerPreview)

    local function RefreshAll()
        if EVL.ApplyAll then EVL.ApplyAll() end
        if activePreviewPage == PAGE_CASTBAR and castbarPreview and castbarPreview.Update then
            castbarPreview:Update()
            ApplyCastbarPreviewStyle(castbarPreview)
            -- Update() re-shows whatever it normally shows, dropdown
            -- included -- re-hide it on every settings-change refresh too,
            -- not just on the initial build (see onPageCacheRestore for the
            -- same fix on the close+reopen path, where this was actually
            -- observed).
            if castbarPreviewHdr then
                HideHeaderPreviewDropdown(castbarPreviewHdr, castbarPreview)
            end
        end
        RefreshHealerManaPreview()
        RefreshInterruptTrackerPreview()
        if RefreshWidgets then RefreshWidgets() end
    end

    -- Re-reads getValue() into every widget built so far (disabled-state greys,
    -- control values, etc). EllesmereUI:RefreshPage() only works for pages open
    -- inside EllesmereUI's own panel (it no-ops without an activeModule/Page),
    -- which our standalone window never sets -- so we drive the same shared
    -- refresh list (EllesmereUI._widgetRefreshList, populated by W:DualRow etc)
    -- directly instead.
    RefreshWidgets = function()
        local rl = EllesmereUI._widgetRefreshList
        if not rl then return end
        for i = 1, #rl do
            local fn = rl[i]
            if fn then fn() end
        end
    end

    ---------------------------------------------------------------------------
    --  QoL page -- small quality-of-life tweaks
    ---------------------------------------------------------------------------
    local function BuildQoLPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local h

        if EllesmereUI.ClearContentHeader then EllesmereUI:ClearContentHeader() end
        parent._showRowDivider = true

        _, h = W:SectionHeader(parent, "VISIBILITY", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Actual Dragonriding Visibility",
              tooltip="EllesmereUI's \"Hide when Dragonriding\" visibility option only hides once you're actually airborne (IsFlying()). This makes it hide as soon as you're on a skyriding-capable mount, before takeoff -- matching \"hide whenever I can Dragonride\".",
              getValue=function() local c = QoL(); return c and c.actualDragonridingVisibility or false end,
              setValue=function(v)
                  local c = QoL(); if c then c.actualDragonridingVisibility = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:SectionHeader(parent, "CHAT", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Suppress Auto /played",
              tooltip="Blocks the automatic \"You have played...\" system message some addons trigger on every login (e.g. XPBarEnhanced requesting play time for its own tracking). Typing /played yourself still works normally.",
              getValue=function() local c = QoL(); return c and c.suppressAutoPlayed or false end,
              setValue=function(v)
                  local c = QoL(); if c then c.suppressAutoPlayed = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:SectionHeader(parent, "STATUS BAR GENERAL", y); y = y - h

        local function SBOff() local c = SB(); return not (c and c.enabled) end
        local function BgOff() local c = SB(); return SBOff() or not (c and c.bgEnabled) end

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Enabled",
              tooltip="A small movable text bar (FPS+Latency / Durability / Clock). Fully independent of EllesmereUIDataBars, so it survives its daily auto-updates. Position it via EllesmereUI Unlock Mode.",
              getValue=function() local c = SB(); return c and c.enabled or false end,
              setValue=function(v)
                  local c = SB(); if c then c.enabled = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Hide While Chatting",
              tooltip="Hides the bar whenever a chat edit box is open (Enter to chat, slash commands, whispers, ...), and shows it again as soon as you close it.",
              disabled=SBOff,
              getValue=function() local c = SB(); return c and c.hideWhileChatting or false end,
              setValue=function(v)
                  local c = SB(); if c then c.hideWhileChatting = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Show FPS + Latency",
              tooltip="One block: \"FPS: 134  MS: 44\". Mouseover shows the full latency + FPS tooltip (memory usage, force GC) copied from EllesmereUIDataBars.",
              disabled=SBOff,
              getValue=function() local c = SBBlock("fps"); return c and c.enabled or false end,
              setValue=function(v)
                  local c = SBBlock("fps"); if c then c.enabled = v end
                  RefreshAll()
              end },
            { type="slider", text="Position",
              min = 1, max = 3, step = 1,
              disabled=SBOff,
              getValue=function() local c = SBBlock("fps"); return c and c.order or 1 end,
              setValue=function(v)
                  local c = SBBlock("fps"); if c then c.order = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Use World Latency",
              tooltip="Off shows home (realm) latency. On shows world (server-side action) latency.",
              disabled=SBOff,
              getValue=function() local c = SBBlock("fps"); return c and c.useWorldLatency or false end,
              setValue=function(v)
                  local c = SBBlock("fps"); if c then c.useWorldLatency = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Show Durability",
              tooltip="Mouseover breaks it down per equipped slot.",
              disabled=SBOff,
              getValue=function() local c = SBBlock("durability"); return c and c.enabled or false end,
              setValue=function(v)
                  local c = SBBlock("durability"); if c then c.enabled = v end
                  RefreshAll()
              end },
            { type="slider", text="Position",
              min = 1, max = 3, step = 1,
              disabled=SBOff,
              getValue=function() local c = SBBlock("durability"); return c and c.order or 2 end,
              setValue=function(v)
                  local c = SBBlock("durability"); if c then c.order = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Show Clock",
              tooltip="Left Click opens the Calendar. Mouseover/right-click/shift-middle-click copied from EllesmereUIDataBars' clock block.",
              disabled=SBOff,
              getValue=function() local c = SBBlock("clock"); return c and c.enabled or false end,
              setValue=function(v)
                  local c = SBBlock("clock"); if c then c.enabled = v end
                  RefreshAll()
              end },
            { type="slider", text="Position",
              min = 1, max = 3, step = 1,
              disabled=SBOff,
              getValue=function() local c = SBBlock("clock"); return c and c.order or 3 end,
              setValue=function(v)
                  local c = SBBlock("clock"); if c then c.order = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:SectionHeader(parent, "STATUS BAR VISUAL", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="slider", text="Width",
              min = 0, max = 600, step = 10,
              tooltip="0 = auto-fit to content. The bar is never narrower than what its enabled blocks need; a higher value stretches it and splits it into equal-width slots, each block centered in its own slot.",
              disabled=SBOff,
              getValue=function() local c = SB(); return c and c.width or 0 end,
              setValue=function(v)
                  local c = SB(); if c then c.width = v end
                  RefreshAll()
              end },
            { type="slider", text="Vertical Padding",
              min = 0, max = 20, step = 1,
              tooltip="Extra space above and below the text, on top of the font's own height.",
              disabled=SBOff,
              getValue=function() local c = SB(); return c and c.vPadding or 3 end,
              setValue=function(v)
                  local c = SB(); if c then c.vPadding = v end
                  RefreshAll()
              end })
        y = y - h

        local sbFontValues, sbFontOrder = EllesmereUI.BuildFontDropdownData()
        _, h = W:DualRow(parent, y,
            { type="dropdown", text="Font",
              values = sbFontValues, order = sbFontOrder,
              disabled=SBOff,
              getValue=function() local c = SB(); return c and c.fontFace or "__global" end,
              setValue=function(v)
                  local c = SB(); if c then c.fontFace = v end
                  RefreshAll()
              end },
            { type="slider", text="Font Size",
              min = 8, max = 32, step = 1,
              disabled=SBOff,
              getValue=function() local c = SB(); return c and c.fontSize or 13 end,
              setValue=function(v)
                  local c = SB(); if c then c.fontSize = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Outline",
              disabled=SBOff,
              getValue=function() local c = SB(); return c and c.outline ~= false end,
              setValue=function(v)
                  local c = SB(); if c then c.outline = v end
                  RefreshAll()
              end },
            { type="colorpicker", text="Label Color",
              tooltip="Colors the field names (\"FPS:\", \"MS:\", \"Durability:\"). The numbers themselves stay colored by value.",
              disabled=SBOff,
              getValue=function()
                  local c = SB()
                  return (c and c.labelColorR or 0.6), (c and c.labelColorG or 0.6), (c and c.labelColorB or 0.6)
              end,
              setValue=function(r, g, b)
                  local c = SB()
                  if c then c.labelColorR = r; c.labelColorG = g; c.labelColorB = b end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Show Background",
              disabled=SBOff,
              getValue=function() local c = SB(); return c and c.bgEnabled or false end,
              setValue=function(v)
                  local c = SB(); if c then c.bgEnabled = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="colorpicker", text="Background Color",
              disabled=BgOff,
              getValue=function()
                  local c = SB()
                  return (c and c.bgColorR or 0), (c and c.bgColorG or 0), (c and c.bgColorB or 0)
              end,
              setValue=function(r, g, b)
                  local c = SB()
                  if c then c.bgColorR = r; c.bgColorG = g; c.bgColorB = b end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="slider", text="Background Opacity",
              min = 0, max = 100, step = 1,
              disabled=BgOff,
              getValue=function() local c = SB(); return c and c.bgOpacity or 50 end,
              setValue=function(v)
                  local c = SB(); if c then c.bgOpacity = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        return math.abs(y)
    end

    ---------------------------------------------------------------------------
    --  Tweaks page -- small hooks into other EllesmereUI modules
    ---------------------------------------------------------------------------
    local function BuildTweaksPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local h

        if EllesmereUI.ClearContentHeader then EllesmereUI:ClearContentHeader() end
        parent._showRowDivider = true

        _, h = W:SectionHeader(parent, "CLASS RESOURCES", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Spec-Based Rune Color",
              tooltip="Death Knight only. Colors runes by your current spec (Blood/Frost/Unholy) instead of the single Runes color from EllesmereUI's Class Resource Colors. Only takes effect while EllesmereUIResourceBars' Class Resource is set to the \"Class Resource Color\" fill mode.",
              getValue=function() local c = QoL(); return c and c.runesSpecColored or false end,
              setValue=function(v)
                  local c = QoL(); if c then c.runesSpecColored = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:SectionHeader(parent, "DEBUFFS", y); y = y - h

        local function NotDispellableColorOff() local c = QoL(); return not (c and c.debuffNotDispellableColor) end

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Debuff Border Color When Not Dispellable",
              tooltip="Player & Target frames. EllesmereUIUnitFrames' Dispel-Type Debuff Border colors a debuff's border by dispel type, but leaves it black when the debuff isn't dispellable. This recolors that black border to a custom color instead.",
              getValue=function() local c = QoL(); return c and c.debuffNotDispellableColor or false end,
              setValue=function(v)
                  local c = QoL(); if c then c.debuffNotDispellableColor = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="colorpicker", text="Border Color",
              disabled=function() return NotDispellableColorOff() end,
              getValue=function()
                  local c = QoL()
                  return (c and c.debuffNotDispellableColorR or 0.5),
                         (c and c.debuffNotDispellableColorG or 0.5),
                         (c and c.debuffNotDispellableColorB or 0.5)
              end,
              setValue=function(r, g, b)
                  local c = QoL()
                  if c then c.debuffNotDispellableColorR = r; c.debuffNotDispellableColorG = g; c.debuffNotDispellableColorB = b end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:SectionHeader(parent, "COOLDOWN MANAGER", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Mirror CDM Cooldowns Visibility to CDM Bars",
              tooltip="EllesmereUICooldownManager's CDM Bars (Cooldowns) page has a Visibility condition; Tracking Bars has none and always shows. This hides Tracking Bars too whenever the Cooldowns viewer is hidden by its own Visibility setting, without touching bars CDM is already hiding for its own reasons.",
              getValue=function() local c = QoL(); return c and c.mirrorCdmCooldownsVisibilityToBars or false end,
              setValue=function(v)
                  local c = QoL(); if c then c.mirrorCdmCooldownsVisibilityToBars = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        return math.abs(y)
    end

    ---------------------------------------------------------------------------
    --  Quick Focus page -- Modifier+Click on a unit frame to set focus
    ---------------------------------------------------------------------------
    local function BuildQuickFocusPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local h

        if EllesmereUI.ClearContentHeader then EllesmereUI:ClearContentHeader() end
        parent._showRowDivider = true

        local function MarkOff() local c = QF(); return not (c and c.setMark) end

        _, h = W:SectionHeader(parent, "GENERAL", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Enabled",
              getValue=function() local c = QF(); return c and c.enabled ~= false end,
              setValue=function(v)
                  local c = QF(); if c then c.enabled = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:SectionHeader(parent, "TRIGGER", y); y = y - h

        local modifierValues = { shift = "Shift", ctrl = "Ctrl", alt = "Alt" }
        local modifierOrder  = { "shift", "ctrl", "alt" }
        local buttonValues = { BUTTON1 = "Left", BUTTON2 = "Right", BUTTON3 = "Middle", BUTTON4 = "Side 4", BUTTON5 = "Side 5" }
        local buttonOrder  = { "BUTTON1", "BUTTON2", "BUTTON3", "BUTTON4", "BUTTON5" }
        _, h = W:DualRow(parent, y,
            { type="dropdown", text="Modifier Key",
              values=modifierValues, order=modifierOrder,
              getValue=function() local c = QF(); return c and c.modifier or "shift" end,
              setValue=function(v)
                  local c = QF(); if c then c.modifier = v end
                  RefreshAll()
              end },
            { type="dropdown", text="Mouse Button",
              values=buttonValues, order=buttonOrder,
              getValue=function() local c = QF(); return c and c.button or "BUTTON1" end,
              setValue=function(v)
                  local c = QF(); if c then c.button = v end
                  RefreshAll()
              end })
        y = y - h

        local markValues = {
            [1] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:16|t Star",
            [2] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_2:16|t Circle",
            [3] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_3:16|t Diamond",
            [4] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_4:16|t Triangle",
            [5] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_5:16|t Moon",
            [6] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_6:16|t Square",
            [7] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_7:16|t Cross",
            [8] = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:16|t Skull",
        }
        local markOrder = { 1, 2, 3, 4, 5, 6, 7, 8 }

        _, h = W:SectionHeader(parent, "RAID MARKER", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Set Raid Marker on Focus",
              getValue=function() local c = QF(); return c and c.setMark or false end,
              setValue=function(v)
                  local c = QF(); if c then c.setMark = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="dropdown", text="Marker",
              values=markValues, order=markOrder,
              disabled=MarkOff,
              getValue=function() local c = QF(); return c and c.markNumber or 3 end,
              setValue=function(v)
                  local c = QF(); if c then c.markNumber = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Safe Mark",
              tooltip="Only sets the marker on castable targets (help/harm), preventing 'invalid target' errors.",
              disabled=MarkOff,
              getValue=function() local c = QF(); return c and c.safeMark or false end,
              setValue=function(v)
                  local c = QF(); if c then c.safeMark = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:SectionHeader(parent, "READY CHECK", y); y = y - h

        local function AnnounceOff() local c = QF(); return not (c and c.announceFocusMarkOnReadyCheck) end

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Announce Focus Mark on Ready Check",
              tooltip="When a ready check starts, announces \"My focus mark is {icon}\" to party/raid chat if your focus has a raid marker.",
              getValue=function() local c = QF(); return c and c.announceFocusMarkOnReadyCheck or false end,
              setValue=function(v)
                  local c = QF(); if c then c.announceFocusMarkOnReadyCheck = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Announce in Party",
              disabled=AnnounceOff,
              getValue=function() local c = QF(); return c and c.announceInParty ~= false end,
              setValue=function(v)
                  local c = QF(); if c then c.announceInParty = v end
                  RefreshAll()
              end },
            { type="toggle", text="Announce in Raid",
              disabled=AnnounceOff,
              getValue=function() local c = QF(); return c and c.announceInRaid ~= false end,
              setValue=function(v)
                  local c = QF(); if c then c.announceInRaid = v end
                  RefreshAll()
              end })
        y = y - h

        return math.abs(y)
    end

    ---------------------------------------------------------------------------
    --  Combat Text page
    ---------------------------------------------------------------------------
    local CT_ALIGN_VALUES = { LEFT = "Left", CENTER = "Center", RIGHT = "Right" }
    local CT_ALIGN_ORDER  = { "LEFT", "CENTER", "RIGHT" }

    -- Per-frame settings block (Text Align/Size, Font/Outline, Rows Limit/Fade
    -- Start, Fade Time) -- shared by Incoming Damage and Incoming Heal. `kind`
    -- ("damage" | "heal") controls the one row that diverges between them.
    local function BuildCTFrameSettings(parent, y, key, sectionLabel, kind)
        local W = EllesmereUI.Widgets
        local h

        _, h = W:SectionHeader(parent, sectionLabel, y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="dropdown", text="Text Align",
              values=CT_ALIGN_VALUES, order=CT_ALIGN_ORDER,
              getValue=function() local c = CT(key); return c and c.align or "CENTER" end,
              setValue=function(v)
                  local c = CT(key); if c then c.align = v end
                  RefreshAll()
              end },
            { type="slider", text="Text Size",
              min = 8, max = 48, step = 1,
              getValue=function() local c = CT(key); return c and c.fontSize or 22 end,
              setValue=function(v)
                  local c = CT(key); if c then c.fontSize = v end
                  RefreshAll()
              end })
        y = y - h

        local fontValues, fontOrder = EllesmereUI.BuildFontDropdownData()
        _, h = W:DualRow(parent, y,
            { type="dropdown", text="Font",
              values=fontValues, order=fontOrder,
              getValue=function() local c = CT(key); return c and c.font or "__global" end,
              setValue=function(v)
                  local c = CT(key); if c then c.font = v end
                  RefreshAll()
              end },
            { type="toggle", text="Outline",
              getValue=function() local c = CT(key); return c and c.outline ~= false end,
              setValue=function(v)
                  local c = CT(key); if c then c.outline = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="slider", text="Rows Limit",
              tooltip="Maximum number of stacked combat text lines shown at once.",
              min = 1, max = 15, step = 1,
              getValue=function() local c = CT(key); return c and c.rowsLimit or 5 end,
              setValue=function(v)
                  local c = CT(key); if c then c.rowsLimit = v end
                  RefreshAll()
              end },
            { type="slider", text="Fade Start",
              tooltip="Seconds a line stays fully visible before it starts fading.",
              min = 0, max = 5, step = 0.1,
              getValue=function() local c = CT(key); return c and c.fadeStart or 1.0 end,
              setValue=function(v)
                  local c = CT(key); if c then c.fadeStart = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="slider", text="Fade Time",
              tooltip="Seconds the fade-out animation itself takes, once it starts.",
              min = 0.1, max = 3, step = 0.1,
              getValue=function() local c = CT(key); return c and c.fadeDuration or 0.5 end,
              setValue=function(v)
                  local c = CT(key); if c then c.fadeDuration = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        if kind == "heal" then
            _, h = W:DualRow(parent, y,
                { type="colorpicker", text="Text Color",
                  getValue=function()
                      local c = CT(key)
                      return (c and c.textR or 0.25), (c and c.textG or 1), (c and c.textB or 0.35)
                  end,
                  setValue=function(r, g, b)
                      local c = CT(key)
                      if c then c.textR = r; c.textG = g; c.textB = b end
                      RefreshAll()
                  end },
                { type="input", text="Prefix",
                  tooltip="Custom text prepended to every Incoming Heal row, e.g. \"Heal: \".",
                  inputWidth = 100,
                  getValue=function() local c = CT(key); return c and c.prefix or "" end,
                  setValue=function(v)
                      local c = CT(key); if c then c.prefix = v end
                      RefreshAll()
                  end })
            y = y - h
        elseif kind == "damage" then
            _, h = W:DualRow(parent, y,
                { type="toggle", text="Color by Type",
                  tooltip="Colors each line by damage school instead of a single fixed color, once the combat text engine is implemented.",
                  getValue=function() local c = CT(key); return c and c.colorByType or false end,
                  setValue=function(v)
                      local c = CT(key); if c then c.colorByType = v end
                      RefreshAll()
                  end },
                { type="input", text="Prefix",
                  tooltip="Custom text prepended to every Incoming Damage row, e.g. \"-\" for \"-55k\". Only applied to an actual number -- special outcomes like Absorb/Dodge/Parry are never prefixed.",
                  inputWidth = 100,
                  getValue=function() local c = CT(key); return c and c.prefix or "" end,
                  setValue=function(v)
                      local c = CT(key); if c then c.prefix = v end
                      RefreshAll()
                  end })
            y = y - h
        end

        return y
    end

    local combatTextTestBtnLbl
    local function CombatTextTestButtonText()
        return (EVL.CombatText_IsTestActive and EVL.CombatText_IsTestActive()) and "Stop Test" or "Start Test"
    end

    local function BuildCombatTextPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local h

        if EllesmereUI.ClearContentHeader then EllesmereUI:ClearContentHeader() end
        parent._showRowDivider = true

        _, h = W:SectionHeader(parent, "GENERAL", y); y = y - h

        local generalRow
        generalRow, h = W:DualRow(parent, y,
            { type="toggle", text="Enabled",
              tooltip="Master switch for the Incoming Damage/Heal frames below.",
              getValue=function()
                  local d = DB(); local ct = d and d.combatText
                  return ct and ct.enabled ~= false
              end,
              setValue=function(v)
                  local d = DB(); local ct = d and d.combatText
                  if ct then ct.enabled = v end
                  RefreshAll()
              end },
            { type="button", text=CombatTextTestButtonText(),
              tooltip="Fakes one incoming damage + one incoming heal event per second on the real frames (same rendering as actual combat), so you can preview position/style/animation without waiting for combat.",
              onClick=function()
                  if EVL.CombatText_ToggleTest then EVL.CombatText_ToggleTest() end
                  if combatTextTestBtnLbl then
                      combatTextTestBtnLbl:SetText(EllesmereUI.L(CombatTextTestButtonText()))
                  end
              end })
        y = y - h

        -- DualRow doesn't support a dynamic button label via getValue (only
        -- toggles/dropdowns/etc re-evaluate on refresh), so the label is
        -- fetched and updated manually, same pattern as EllesmereUI's own
        -- Activate/Deactivate Party Mode button (EUI_PartyMode_Options.lua).
        if generalRow and generalRow._rightRegion and generalRow._rightRegion._control then
            local btn = generalRow._rightRegion._control
            for i = 1, btn:GetNumRegions() do
                local rgn = select(i, btn:GetRegions())
                if rgn and rgn.GetText and rgn:GetText() then
                    combatTextTestBtnLbl = rgn
                    break
                end
            end
        end
        if combatTextTestBtnLbl and EllesmereUI.RegisterWidgetRefresh then
            EllesmereUI.RegisterWidgetRefresh(function()
                combatTextTestBtnLbl:SetText(EllesmereUI.L(CombatTextTestButtonText()))
            end)
        end

        _, h = W:SectionHeader(parent, "FRAMES", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Incoming Damage",
              tooltip="Shows a movable Incoming Damage frame. Position it in Unlock Mode.",
              getValue=function() local c = CT("incomingDamage"); return c and c.enabled ~= false end,
              setValue=function(v)
                  local c = CT("incomingDamage"); if c then c.enabled = v end
                  RefreshAll()
              end },
            { type="toggle", text="Incoming Heal",
              tooltip="Shows a movable Incoming Heal frame. Position it in Unlock Mode.",
              getValue=function() local c = CT("incomingHeal"); return c and c.enabled ~= false end,
              setValue=function(v)
                  local c = CT("incomingHeal"); if c then c.enabled = v end
                  RefreshAll()
              end })
        y = y - h

        y = BuildCTFrameSettings(parent, y, "incomingDamage", "INCOMING DAMAGE", "damage")
        y = BuildCTFrameSettings(parent, y, "incomingHeal", "INCOMING HEAL", "heal")

        do
            local fontPath = (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
            local infoFrame = CreateFrame("Frame", nil, parent)
            infoFrame:SetSize(parent:GetWidth(), 20)
            infoFrame:SetPoint("TOP", parent, "TOP", 0, y - 10)
            infoFrame._isSpacer = true
            local infoLabel = infoFrame:CreateFontString(nil, "OVERLAY")
            infoLabel:SetFont(fontPath, 13, "")
            infoLabel:SetTextColor(1, 1, 1, 0.6)
            infoLabel:SetPoint("CENTER")
            infoLabel:SetText(EllesmereUI.L("Open Unlock Mode to reposition these frames, or use Start Test above to preview them live without waiting for combat."))
            y = y - 30
        end

        return math.abs(y)
    end

    ---------------------------------------------------------------------------
    --  Target Castbar page
    ---------------------------------------------------------------------------
    -- CLICK NAVIGATION for the Target Castbar preview -- same pattern as the
    -- Interrupt Tracker / Healer Mana previews above.
    local cbGlowFrame
    local function PlayCastbarGlow(targetFrame)
        if not targetFrame then return end
        if not cbGlowFrame then
            cbGlowFrame = CreateFrame("Frame")
            local c = EllesmereUI.ELLESMERE_GREEN
            local function MkEdge()
                local t = cbGlowFrame:CreateTexture(nil, "OVERLAY", nil, 7)
                t:SetColorTexture(c.r, c.g, c.b, 1)
                return t
            end
            cbGlowFrame._top = MkEdge()
            cbGlowFrame._bot = MkEdge()
            cbGlowFrame._lft = MkEdge()
            cbGlowFrame._rgt = MkEdge()
            cbGlowFrame._top:SetHeight(2)
            cbGlowFrame._top:SetPoint("TOPLEFT"); cbGlowFrame._top:SetPoint("TOPRIGHT")
            cbGlowFrame._bot:SetHeight(2)
            cbGlowFrame._bot:SetPoint("BOTTOMLEFT"); cbGlowFrame._bot:SetPoint("BOTTOMRIGHT")
            cbGlowFrame._lft:SetWidth(2)
            cbGlowFrame._lft:SetPoint("TOPLEFT", cbGlowFrame._top, "BOTTOMLEFT")
            cbGlowFrame._lft:SetPoint("BOTTOMLEFT", cbGlowFrame._bot, "TOPLEFT")
            cbGlowFrame._rgt:SetWidth(2)
            cbGlowFrame._rgt:SetPoint("TOPRIGHT", cbGlowFrame._top, "BOTTOMRIGHT")
            cbGlowFrame._rgt:SetPoint("BOTTOMRIGHT", cbGlowFrame._bot, "TOPRIGHT")
        end
        cbGlowFrame:SetParent(targetFrame)
        cbGlowFrame:SetAllPoints(targetFrame)
        cbGlowFrame:SetFrameLevel(targetFrame:GetFrameLevel() + 5)
        cbGlowFrame:SetAlpha(1)
        cbGlowFrame:Show()
        local elapsed = 0
        cbGlowFrame:SetScript("OnUpdate", function(self, dt)
            elapsed = elapsed + dt
            if elapsed >= 0.75 then
                self:Hide(); self:SetScript("OnUpdate", nil); return
            end
            self:SetAlpha(1 - elapsed / 0.75)
        end)
    end

    local function NavigateToCastbarSetting(key)
        local m = castbarClickTargets and castbarClickTargets[key]
        if not m or not m.section or not m.target then return end
        local sf = EllesmereUI._scrollFrame
        if not sf then return end
        local _, _, _, _, headerY = m.section:GetPoint(1)
        if not headerY then return end
        local scrollPos = math.max(0, math.abs(headerY) - 40)
        EllesmereUI.SmoothScrollTo(scrollPos)
        local glowTarget = m.target
        if m.slotSide then
            local region = (m.slotSide == "left") and m.target._leftRegion or m.target._rightRegion
            if region then glowTarget = region end
        end
        C_Timer.After(0.15, function() PlayCastbarGlow(glowTarget) end)
    end

    local function CreateCastbarHitOverlay(element, mappingKey, isText, frameLevelOverride)
        local anchor = isText and element:GetParent() or element
        if not anchor.CreateTexture then anchor = anchor:GetParent() end
        local btn = CreateFrame("Button", nil, anchor)
        if isText then
            local function ResizeToText()
                local ok, tw, th = pcall(function()
                    local w = element:GetStringWidth() or 0
                    local hh = element:GetStringHeight() or 0
                    if w < 4 then w = 4 end
                    if hh < 4 then hh = 4 end
                    return w, hh
                end)
                if not ok then tw = 40; th = 12 end
                btn:SetSize(tw + 4, th + 4)
            end
            ResizeToText()
            local justify = element:GetJustifyH()
            if justify == "RIGHT" then btn:SetPoint("RIGHT", element, "RIGHT", 2, 0)
            elseif justify == "CENTER" then btn:SetPoint("CENTER", element, "CENTER", 0, 0)
            else btn:SetPoint("LEFT", element, "LEFT", -2, 0) end
            btn:SetScript("OnShow", function() ResizeToText() end)
        else
            btn:SetAllPoints(element)
        end
        btn:SetFrameLevel(frameLevelOverride or (anchor:GetFrameLevel() + 20))
        btn:RegisterForClicks("LeftButtonDown")
        local c = EllesmereUI.ELLESMERE_GREEN
        local brd = EllesmereUI.PP.CreateBorder(btn, c.r, c.g, c.b, 1, 2, "OVERLAY", 7)
        brd:Hide()
        btn:SetScript("OnEnter", function() brd:Show() end)
        btn:SetScript("OnLeave", function() brd:Hide() end)
        btn:SetScript("OnMouseDown", function() NavigateToCastbarSetting(mappingKey) end)
        return btn
    end

    -- Attaches hit overlays to the castbar preview's icon / icon text / bar.
    -- Unlike the Interrupt Tracker / Healer Mana previews (which own
    -- persistent, never-recreated bar frames), this reuses Unit Frames' OWN
    -- preview -- its outer wrapper and/or inner sub-widgets (_castbar,
    -- _castIconFrame) may or may not be the same objects from one header
    -- rebuild to the next (rebuilds happen on every page display, not just
    -- the first). Rather than guess at that lifecycle, this just always
    -- hides whatever overlay buttons it made last time and makes fresh ones
    -- for whatever the CURRENT sub-widgets are -- cheap, and correct
    -- regardless of what got recreated underneath.
    local castbarOverlayButtons = {}
    local function AttachCastbarPreviewOverlays()
        if not castbarClickTargets then return end
        if not (castbarPreview and castbarPreview._castbar) then return end

        for i = 1, #castbarOverlayButtons do
            castbarOverlayButtons[i]:Hide()
        end
        wipe(castbarOverlayButtons)

        local lvl = castbarPreview:GetFrameLevel() + 30
        castbarOverlayButtons[#castbarOverlayButtons + 1] =
            CreateCastbarHitOverlay(castbarPreview._castbar, "castbar", false, lvl)
        local iconFrame = castbarPreview._castIconFrame
        if iconFrame then
            castbarOverlayButtons[#castbarOverlayButtons + 1] =
                CreateCastbarHitOverlay(iconFrame, "icon", false, lvl + 10)
            local fs = iconFrame._evlUninterruptibleFS
            if fs then
                castbarOverlayButtons[#castbarOverlayButtons + 1] =
                    CreateCastbarHitOverlay(fs, "iconText", true, lvl + 15)
            end
        end
    end

    -- Everything that needs to be true about the reused Unit Frames preview
    -- for THIS page specifically -- buffs/debuffs hidden, click overlays
    -- attached, dropdown hidden -- bundled into one idempotent call so it
    -- can be re-run from wherever the preview might become visible again
    -- (initial build, onPageCacheRestore, RefreshAll, or the preview's own
    -- OnShow) without duplicating the list of steps at each call site.
    local function PolishCastbarPreview()
        if not castbarPreview then return end
        if castbarPreview._buffIcons then
            for i = 1, #castbarPreview._buffIcons do
                if castbarPreview._buffIcons[i] then castbarPreview._buffIcons[i]:Hide() end
            end
        end
        if castbarPreview._debuffIcons then
            for i = 1, #castbarPreview._debuffIcons do
                if castbarPreview._debuffIcons[i] then castbarPreview._debuffIcons[i]:Hide() end
            end
        end
        AttachCastbarPreviewOverlays()
        if castbarPreviewHdr then
            HideHeaderPreviewDropdown(castbarPreviewHdr, castbarPreview)
        end
    end

    -- EllesmereUIUnitFrames' own "Main Frames" header-builder is a lazily-
    -- assigned local in ITS options file, only set as a side effect of that
    -- page's own build function actually running -- i.e. only once the user
    -- has opened Unit Frames' options at least once this session. Force
    -- that build ONCE into a hidden, off-screen frame so it happens
    -- regardless, instead of asking the user to go open that page first.
    -- The shared content-header methods are stubbed for the duration so the
    -- hidden build can't clobber whatever's actually on screen right now.
    -- (Previously suspected of causing the dropdown/click-overlay breakage
    -- on tab-switch -- it wasn't; that was onPageCacheRestore never
    -- re-polishing the preview on a same-session tab switch, fixed above.
    -- Safe to bring back now that the real cause is fixed.)
    local function PrebuildUnitFramesPreviewOnce(ufConfig)
        if EllesmereUI._evlUFPrebuilt or not (ufConfig and ufConfig.buildPage) then return end
        EllesmereUI._evlUFPrebuilt = true
        local saved = {}
        for _, m in ipairs({ "SetContentHeader", "UpdateContentHeaderHeight", "SetContentHeaderHeightSilent", "ClearContentHeader", "HideContentHeader" }) do
            saved[m] = EllesmereUI[m]
            EllesmereUI[m] = function() end
        end
        local hidden = CreateFrame("Frame", nil, UIParent)
        hidden:Hide()
        pcall(ufConfig.buildPage, "Main Frames", hidden, -6)
        for m, fn in pairs(saved) do EllesmereUI[m] = fn end
    end

    local function BuildCastbarHeaderPreview(hdr, hdrW)
        activePreviewPage = PAGE_CASTBAR
        castbarPreviewHdr = hdr
        local modules = EllesmereUI and EllesmereUI._modules
        local ufConfig = modules and modules.EllesmereUIUnitFrames
        local ufBuilder = ufConfig and ufConfig.getHeaderBuilder and ufConfig.getHeaderBuilder("Main Frames")
        local totalH

        castbarPreview = nil

        if not ufBuilder then
            PrebuildUnitFramesPreviewOnce(ufConfig)
            ufBuilder = ufConfig and ufConfig.getHeaderBuilder and ufConfig.getHeaderBuilder("Main Frames")
        end

        if not ufBuilder then
            local fontPath = (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
            local fs = hdr._evlFallbackFS or hdr:CreateFontString(nil, "OVERLAY")
            hdr._evlFallbackFS = fs
            fs:SetFont(fontPath, 13, "")
            fs:SetTextColor(1, 1, 1, 0.65)
            fs:ClearAllPoints()
            fs:SetPoint("TOP", hdr, "TOP", 0, -28)
            fs:SetText("Target preview unavailable (EllesmereUIUnitFrames not loaded).")
            fs:Show()
            return 80
        end

        if hdr._evlFallbackFS then
            hdr._evlFallbackFS:Hide()
        end

        if EllesmereUI._setUnitFrameUnit then
            EllesmereUI._setUnitFrameUnit("target")
        end

        totalH = ufBuilder(hdr, hdrW) or 260
        castbarPreview = GetCastbarPreviewTarget(hdr)
        if castbarPreview then
            local scale = castbarPreview._previewScale or 1
            local initBuffTopPad = castbarPreview._buffTopPad or 0
            local y = (-20 - initBuffTopPad) / scale
            castbarPreview:ClearAllPoints()
            castbarPreview:SetPoint("TOP", hdr, "TOP", 0, y)
            castbarPreview._lastOY = y
            ApplyCastbarPreviewStyle(castbarPreview)
            PolishCastbarPreview()

            -- Belt-and-suspenders: a same-session tab switch back to this
            -- page doesn't re-run this builder at all (EllesmereUI just
            -- re-parents previously-stashed header frames and shows them --
            -- see onPageCacheRestore for the module hook that fires
            -- instead). Whatever that reparent-and-show sequence triggers on
            -- the Unit Frames side (its own Update()-driven refresh) can
            -- re-reveal the dropdown/buffs AFTER our onPageCacheRestore fix
            -- already ran, if its own refresh is asynchronous. Hooking the
            -- preview's own OnShow re-polishes every time it actually
            -- becomes visible again, regardless of exactly when that
            -- happens or what triggered it -- no timing guesswork needed.
            if not castbarPreview._evlOnShowHooked then
                castbarPreview._evlOnShowHooked = true
                castbarPreview:HookScript("OnShow", function() PolishCastbarPreview() end)
            end
        end

        HideHeaderPreviewDropdown(hdr, castbarPreview)
        return math.max(60, totalH - 42)
    end

    local function BuildCastbarPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local h

        castbarHeaderBuilder = BuildCastbarHeaderPreview
        if EllesmereUI.SetContentHeader then
            EllesmereUI:SetContentHeader(castbarHeaderBuilder)
        elseif EllesmereUI.ClearContentHeader then
            EllesmereUI:ClearContentHeader()
        end
        parent._showRowDivider = true

        _, h = W:SectionHeader(parent, "GENERAL", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Enabled",
              tooltip="Master switch for all castbar modifications below (icon layout, overlay mode, etc).",
              getValue=function() local c = Castbar(); return c and c.enabled ~= false end,
              setValue=function(v)
                  local c = Castbar(); if c then c.enabled = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="label", text="" })
        y = y - h

        -- Captured so the preview's click-to-navigate overlays (attached at
        -- the end of this function) can scroll to / glow the exact row.
        local iconSection, iconRow, iconTextRow, barSection, overlayRow

        iconSection, h = W:SectionHeader(parent, "ICON", y); y = y - h

        local function CastbarOff() local c = Castbar(); return not c or c.enabled == false end
        local function IconNotDetached() local c = Castbar(); return CastbarOff() or not (c and c.detachIcon) end
        local function IconTextOff() local c = Castbar(); return CastbarOff() or not (c and c.showUninterruptibleText) end

        iconRow, h = W:DualRow(parent, y,
            { type="toggle", text="Detach Icon",
              tooltip="Moves the cast icon off the castbar so it can be positioned independently.",
              disabled=CastbarOff,
              getValue=function() local c = Castbar(); return c and c.detachIcon or false end,
              setValue=function(v)
                  local c = Castbar(); if c then c.detachIcon = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="slider", text="Icon Size",
              min = 16, max = 64, step = 1,
              disabled=CastbarOff,
              getValue=function() local c = Castbar(); return c and c.iconSize or 32 end,
              setValue=function(v)
                  local c = Castbar(); if c then c.iconSize = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="slider", text="Icon Border Width",
              min = 0, max = 8, step = 1,
              disabled=CastbarOff,
              getValue=function() local c = Castbar(); return c and c.iconBorderWidth or 1 end,
              setValue=function(v)
                  local c = Castbar(); if c then c.iconBorderWidth = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        local anchorValues = { RIGHT = "Right of Bar", LEFT = "Left of Bar", TOP = "Above Bar", BOTTOM = "Below Bar" }
        local anchorOrder  = { "RIGHT", "LEFT", "TOP", "BOTTOM" }
        _, h = W:DualRow(parent, y,
            { type="dropdown", text="Detach Position",
              values=anchorValues, order=anchorOrder,
              disabled=IconNotDetached,
              getValue=function() local c = Castbar(); return c and c.detachAnchor or "RIGHT" end,
              setValue=function(v)
                  local c = Castbar(); if c then c.detachAnchor = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="slider", text="Detach X Offset",
              min = -80, max = 80, step = 1,
              disabled=IconNotDetached,
              getValue=function() local c = Castbar(); return c and c.detachXOffset or 0 end,
              setValue=function(v)
                  local c = Castbar(); if c then c.detachXOffset = v end
                  RefreshAll()
              end },
            { type="slider", text="Detach Y Offset",
              min = -80, max = 80, step = 1,
              disabled=IconNotDetached,
              getValue=function() local c = Castbar(); return c and c.detachYOffset or 0 end,
              setValue=function(v)
                  local c = Castbar(); if c then c.detachYOffset = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Desaturate on Uninterruptible",
              tooltip="Desaturates the cast icon when the cast cannot be interrupted.",
              disabled=CastbarOff,
              getValue=function() local c = Castbar(); return c and c.desaturateUninterruptible ~= false end,
              setValue=function(v)
                  local c = Castbar(); if c then c.desaturateUninterruptible = v end
                  RefreshAll()
              end },
            { type="toggle", text="Text Over Icon on Uninterruptible",
              tooltip="Overlays text on the cast icon when the cast cannot be interrupted.",
              disabled=CastbarOff,
              getValue=function() local c = Castbar(); return c and c.showUninterruptibleText ~= false end,
              setValue=function(v)
                  local c = Castbar(); if c then c.showUninterruptibleText = v end
                  RefreshAll()
                  RefreshWidgets()
              end })
        y = y - h

        iconTextRow, h = W:DualRow(parent, y,
            { type="input", text="Icon Text",
              inputWidth = 60,
              disabled=IconTextOff,
              getValue=function() local c = Castbar(); return c and c.uninterruptibleText or "X" end,
              setValue=function(v)
                  local c = Castbar(); if c then c.uninterruptibleText = v end
                  RefreshAll()
              end },
            { type="colorpicker", text="Icon Text Color",
              disabled=IconTextOff,
              getValue=function()
                  local c = Castbar()
                  return (c and c.uninterruptibleTextR or 1), (c and c.uninterruptibleTextG or 0.2), (c and c.uninterruptibleTextB or 0.2)
              end,
              setValue=function(r, g, b)
                  local c = Castbar()
                  if c then c.uninterruptibleTextR = r; c.uninterruptibleTextG = g; c.uninterruptibleTextB = b end
                  RefreshAll()
              end })
        y = y - h

        local ubFontValues, ubFontOrder = EllesmereUI.BuildFontDropdownData()
        _, h = W:DualRow(parent, y,
            { type="dropdown", text="Icon Text Font",
              values=ubFontValues, order=ubFontOrder,
              disabled=IconTextOff,
              getValue=function() local c = Castbar(); return c and c.uninterruptibleTextFont or "__global" end,
              setValue=function(v)
                  local c = Castbar(); if c then c.uninterruptibleTextFont = v end
                  RefreshAll()
              end },
            { type="slider", text="Icon Text Size",
              min = 8, max = 72, step = 1,
              disabled=IconTextOff,
              getValue=function() local c = Castbar(); return c and c.uninterruptibleTextSize or 12 end,
              setValue=function(v)
                  local c = Castbar(); if c then c.uninterruptibleTextSize = v end
                  RefreshAll()
              end })
        y = y - h

        barSection, h = W:SectionHeader(parent, "BAR", y); y = y - h

        overlayRow, h = W:DualRow(parent, y,
            { type="toggle", text="Overlay on Target Frame",
              tooltip="Makes the castbar itself transparent and overlays it on the target frame, leaving only text and spark visible.",
              disabled=CastbarOff,
              getValue=function() local c = Castbar(); return c and c.overlayMode or false end,
              setValue=function(v)
                  local c = Castbar(); if c then c.overlayMode = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        castbarClickTargets = {
            icon     = { section = iconSection, target = iconRow },
            iconText = { section = iconSection, target = iconTextRow },
            castbar  = { section = barSection,  target = overlayRow },
        }
        AttachCastbarPreviewOverlays()

        return math.abs(y)
    end

    ---------------------------------------------------------------------------
    --  Healer Mana page
    ---------------------------------------------------------------------------
    -- Standalone preview groups -- Party (1 row) and Raid (4 rows), side by
    -- side -- independent of Enabled/Unlock Mode, always showing live
    -- samples for BOTH frames' own settings (EVL.HealerMana_RefreshPreviewGroup).
    -- Built via the HEADER mechanism (like BuildCastbarHeaderPreview), not
    -- buildPage's content area: getHeaderBuilder's function is invoked fresh
    -- on every page display (including a cached-page revisit), whereas
    -- buildPage only runs once per session for an already-built page. A
    -- previous content-area version of this preview went permanently
    -- invisible after the underlying page content frame got recycled (no
    -- error, no fix from Show()/SetPoint/tab-switching, only /reloadui) --
    -- because SetPoint alone never re-parents a frame, so a holder created
    -- against a stale "parent" argument stays a child of that stale, no
    -- longer relevant frame forever. Re-parenting inside RefreshHealerManaPreview
    -- (SetParent(hdr)) on every invocation fixes that at the root instead of
    -- just papering over it.
    local function BuildHealerManaHeaderPreview(hdr, hdrW)
        healerManaPreviewHdr = hdr
        activePreviewPage = PAGE_HEALER_MANA
        return RefreshHealerManaPreview() or 88
    end

    local function BuildHealerManaPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local h

        healerManaHeaderBuilder = BuildHealerManaHeaderPreview
        if EllesmereUI.SetContentHeader then
            EllesmereUI:SetContentHeader(healerManaHeaderBuilder)
        elseif EllesmereUI.ClearContentHeader then
            EllesmereUI:ClearContentHeader()
        end
        parent._showRowDivider = true

        local function IconOff(key) local c = HMFrame(key); return c and c.showIcon == false end
        local function ManaColorOff(key) local c = HMFrame(key); return not (c and c.useCustomManaColor) end
        local fontValues, fontOrder = EllesmereUI.BuildFontDropdownData()

        -- Captured per key ("party"/"raid") so the preview's click-to-
        -- navigate overlays (attached after both sections are built) can
        -- scroll to / glow the exact row for whichever frame was clicked.
        local sectionRefs = {}

        -- Every visual setting is independent per frame; called once for
        -- "party" and once for "raid" below.
        local function BuildHealerFrameSection(sectionLabel, key)
            local sectionFrame, iconRow, fontRow, manaColorRow
            sectionFrame, h = W:SectionHeader(parent, sectionLabel, y); y = y - h

            local raidRow = (key == "raid") and
                { type="dropdown", text="Raid Grow Direction",
                  values = { VERTICAL = "Vertical", HORIZONTAL = "Horizontal" },
                  order  = { "VERTICAL", "HORIZONTAL" },
                  getValue=function() local c = HMFrame("raid"); return c and c.raidGrowDirection or "VERTICAL" end,
                  setValue=function(v)
                      local c = HMFrame("raid"); if c then c.raidGrowDirection = v end
                      RefreshAll()
                  end }
                or { type="label", text="" }

            _, h = W:DualRow(parent, y,
                { type="toggle", text="Enabled",
                  tooltip="Shows mana% for healers in your " .. (key == "raid" and "raid." or "party."),
                  getValue=function() local c = HMFrame(key); return c and c.enabled ~= false end,
                  setValue=function(v)
                      local c = HMFrame(key); if c then c.enabled = v end
                      RefreshAll()
                      RefreshWidgets()
                  end },
                raidRow)
            y = y - h

            iconRow, h = W:DualRow(parent, y,
                { type="toggle", text="Show Icon",
                  tooltip="Shows the healer's spec icon next to their name. Off collapses the row to text only.",
                  getValue=function() local c = HMFrame(key); return c and c.showIcon ~= false end,
                  setValue=function(v)
                      local c = HMFrame(key); if c then c.showIcon = v end
                      RefreshAll()
                      RefreshWidgets()
                  end },
                { type="slider", text="Icon Size",
                  min = 12, max = 72, step = 1,
                  disabled=function() return IconOff(key) end,
                  getValue=function() local c = HMFrame(key); return c and c.iconSize or 24 end,
                  setValue=function(v)
                      local c = HMFrame(key); if c then c.iconSize = v end
                      RefreshAll()
                  end })
            y = y - h

            _, h = W:DualRow(parent, y,
                { type="toggle", text="One Line Mode",
                  tooltip="Only while Show Icon is off: puts the name and mana% on a single line instead of stacking mana under the name.",
                  disabled=function() return not IconOff(key) end,
                  getValue=function() local c = HMFrame(key); return c and c.oneLineMode or false end,
                  setValue=function(v)
                      local c = HMFrame(key); if c then c.oneLineMode = v end
                      RefreshAll()
                  end },
                { type="slider", text="Max Name Length",
                  min = 0, max = 10, step = 1,
                  tooltip="Truncates each healer's name to this many characters. 0 = unlimited.",
                  getValue=function() local c = HMFrame(key); return c and c.nameMaxLength or 0 end,
                  setValue=function(v)
                      local c = HMFrame(key); if c then c.nameMaxLength = v end
                      RefreshAll()
                  end })
            y = y - h

            fontRow, h = W:DualRow(parent, y,
                { type="dropdown", text="Font",
                  values = fontValues, order = fontOrder,
                  getValue=function() local c = HMFrame(key); return c and c.fontFace or "__global" end,
                  setValue=function(v)
                      local c = HMFrame(key); if c then c.fontFace = v end
                      RefreshAll()
                  end },
                { type="slider", text="Font Size",
                  min = 8, max = 32, step = 1,
                  getValue=function() local c = HMFrame(key); return c and c.fontSize or 12 end,
                  setValue=function(v)
                      local c = HMFrame(key); if c then c.fontSize = v end
                      RefreshAll()
                  end })
            y = y - h

            manaColorRow, h = W:DualRow(parent, y,
                { type="toggle", text="Use Custom Mana Color",
                  tooltip="When off, mana% text uses the default color (#008CFF).",
                  getValue=function() local c = HMFrame(key); return c and c.useCustomManaColor or false end,
                  setValue=function(v)
                      local c = HMFrame(key); if c then c.useCustomManaColor = v end
                      RefreshAll()
                      RefreshWidgets()
                  end },
                { type="colorpicker", text="Mana Text Color",
                  disabled=function() return ManaColorOff(key) end,
                  getValue=function()
                      local c = HMFrame(key)
                      return (c and c.manaColorR or 1), (c and c.manaColorG or 1), (c and c.manaColorB or 1)
                  end,
                  setValue=function(r, g, b)
                      local c = HMFrame(key)
                      if c then c.manaColorR = r; c.manaColorG = g; c.manaColorB = b end
                      RefreshAll()
                  end })
            y = y - h

            sectionRefs[key] = { section = sectionFrame, iconRow = iconRow, fontRow = fontRow, manaColorRow = manaColorRow }
        end

        _, h = W:SectionHeader(parent, "GENERAL", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Enabled",
              tooltip="Master switch for Healer Mana. Open EllesmereUI Unlock Mode to preview and position the Party/Raid frames.",
              getValue=function() local c = HealerMana(); return c and c.enabled or false end,
              setValue=function(v)
                  local c = HealerMana(); if c then c.enabled = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="label", text="" })
        y = y - h

        BuildHealerFrameSection("PARTY", "party")
        BuildHealerFrameSection("RAID", "raid")

        local partyRefs, raidRefs = sectionRefs.party, sectionRefs.raid
        healerManaClickTargets = {
            party_icon = { section = partyRefs.section, target = partyRefs.iconRow },
            party_name = { section = partyRefs.section, target = partyRefs.fontRow },
            party_mana = { section = partyRefs.section, target = partyRefs.manaColorRow, slotSide = "right" },
            raid_icon  = { section = raidRefs.section,  target = raidRefs.iconRow },
            raid_name  = { section = raidRefs.section,  target = raidRefs.fontRow },
            raid_mana  = { section = raidRefs.section,  target = raidRefs.manaColorRow, slotSide = "right" },
        }
        AttachHealerManaPreviewOverlays()

        return math.abs(y)
    end

    ---------------------------------------------------------------------------
    --  Interrupt Tracker page
    ---------------------------------------------------------------------------
    local function BuildInterruptTrackerHeaderPreview(hdr, hdrW)
        interruptTrackerPreviewHdr = hdr
        activePreviewPage = PAGE_INTERRUPT_TRACKER
        return RefreshInterruptTrackerPreview() or 60
    end

    local function BuildInterruptTrackerPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local h

        interruptTrackerHeaderBuilder = BuildInterruptTrackerHeaderPreview
        if EllesmereUI.SetContentHeader then
            EllesmereUI:SetContentHeader(interruptTrackerHeaderBuilder)
        elseif EllesmereUI.ClearContentHeader then
            EllesmereUI:ClearContentHeader()
        end
        parent._showRowDivider = true

        local function ITOff() return not (IT() and IT().enabled) end
        local function ReadyColorPickerOff() local c = IT(); return c and c.keepReadyClassColor end
        local function NotDkTalent() return ITOff() or not (IT() and IT().dkMindFreezeCDRTalent) end
        local function NameColorReadyCustomOff() return ITOff() or (IT() and IT().nameColorReadyMode == "class") end
        local function NameColorCooldownCustomOff() return ITOff() or (IT() and IT().nameColorCooldownMode == "class") end

        local barTexValues, barTexOrder = BuildBarTextureDropdownData()
        local fontValues, fontOrder = EllesmereUI.BuildFontDropdownData()

        -- Captured so the preview's click-to-navigate overlays (built at the
        -- end of this function) can scroll to / glow the exact row.
        local barAppearanceSection, iconPosRow, textColorRow
        local stateColorsSection, readyColorRow, readyTextColorRow, cooldownColorRow
        local nameColorSection, nameColorReadyRow, nameColorCooldownRow

        _, h = W:SectionHeader(parent, "GENERAL", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Enabled",
              tooltip="Shows one status bar per tracked interrupt (yours + party members'). Open EllesmereUI Unlock Mode to preview and position/resize the window.",
              getValue=function() local c = IT(); return c and c.enabled or false end,
              setValue=function(v)
                  local c = IT(); if c then c.enabled = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="label", text="" })
        y = y - h

        barAppearanceSection, h = W:SectionHeader(parent, "BAR APPEARANCE", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="slider", text="Bar Width",
              min = 60, max = 400, step = 5,
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.barWidth or 200 end,
              setValue=function(v)
                  local c = IT(); if c then c.barWidth = v end
                  RefreshAll()
              end },
            { type="slider", text="Bar Height",
              min = 10, max = 60, step = 1,
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.barHeight or 24 end,
              setValue=function(v)
                  local c = IT(); if c then c.barHeight = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="slider", text="Bar Spacing",
              min = 0, max = 30, step = 1,
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.barSpacing or 6 end,
              setValue=function(v)
                  local c = IT(); if c then c.barSpacing = v end
                  RefreshAll()
              end },
            { type="slider", text="Max Bars",
              min = 1, max = 20, step = 1,
              tooltip="Size of the bar pool -- the most rows that can ever be shown at once.",
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.maxBars or 10 end,
              setValue=function(v)
                  local c = IT(); if c then c.maxBars = v end
                  RefreshAll()
              end })
        y = y - h

        iconPosRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Icon Position",
              values = { left = "Left", right = "Right" },
              order  = { "left", "right" },
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.iconPosition or "left" end,
              setValue=function(v)
                  local c = IT(); if c then c.iconPosition = v end
                  RefreshAll()
              end },
            { type="slider", text="Icon Gap",
              min = 0, max = 20, step = 1,
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.iconGap or 4 end,
              setValue=function(v)
                  local c = IT(); if c then c.iconGap = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="dropdown", text="Bar Texture",
              values = barTexValues, order = barTexOrder,
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.barTexture or "Blizzard" end,
              setValue=function(v)
                  local c = IT(); if c then c.barTexture = v end
                  RefreshAll()
              end },
            { type="toggle", text="Reverse Fill",
              tooltip="Bar drains right-to-left instead of left-to-right.",
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.reverseFill or false end,
              setValue=function(v)
                  local c = IT(); if c then c.reverseFill = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="slider", text="Border Thickness",
              min = 0, max = 4, step = 1,
              tooltip="Per-bar and per-icon border. 0 = no border.",
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.borderThickness or 1 end,
              setValue=function(v)
                  local c = IT(); if c then c.borderThickness = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="dropdown", text="Font",
              values = fontValues, order = fontOrder,
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.fontFace or "__global" end,
              setValue=function(v)
                  local c = IT(); if c then c.fontFace = v end
                  RefreshAll()
              end },
            { type="slider", text="Font Size",
              min = 8, max = 32, step = 1,
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.fontSize or 12 end,
              setValue=function(v)
                  local c = IT(); if c then c.fontSize = v end
                  RefreshAll()
              end })
        y = y - h

        textColorRow, h = W:DualRow(parent, y,
            { type="colorpicker", text="Text Color",
              disabled=ITOff,
              getValue=function()
                  local c = IT()
                  return (c and c.textColorR or 1), (c and c.textColorG or 1), (c and c.textColorB or 1)
              end,
              setValue=function(r, g, b)
                  local c = IT()
                  if c then c.textColorR = r; c.textColorG = g; c.textColorB = b end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="colorpicker", text="Bar Background Color",
              hasAlpha=true,
              tooltip="While ready, this alpha is also scaled by Ready Color's own alpha -- so a fully transparent Ready Color fades the background too, not just the fill. On cooldown / no data, only this alpha applies.",
              disabled=ITOff,
              getValue=function()
                  local c = IT()
                  return (c and c.barBgColorR or 0.08), (c and c.barBgColorG or 0.08), (c and c.barBgColorB or 0.08), (c and c.barBgColorA or 0.95)
              end,
              setValue=function(r, g, b, a)
                  local c = IT()
                  if c then c.barBgColorR = r; c.barBgColorG = g; c.barBgColorB = b; c.barBgColorA = a end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        stateColorsSection, h = W:SectionHeader(parent, "COOLDOWN STATE COLORS", y); y = y - h

        readyColorRow, h = W:DualRow(parent, y,
            { type="toggle", text="Ready Uses Class Color",
              tooltip="When on, a ready bar is tinted with the tracked player's class color instead of the Ready Color below.",
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.keepReadyClassColor or false end,
              setValue=function(v)
                  local c = IT(); if c then c.keepReadyClassColor = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="colorpicker", text="Ready Color",
              hasAlpha=true,
              tooltip="Alpha controls how translucent the bar fill looks once ready.",
              disabled=function() return ITOff() or ReadyColorPickerOff() end,
              getValue=function()
                  local c = IT()
                  return (c and c.readyColorR or 0), (c and c.readyColorG or 0.78), (c and c.readyColorB or 0.2), (c and c.readyColorA or 1)
              end,
              setValue=function(r, g, b, a)
                  local c = IT()
                  if c then c.readyColorR = r; c.readyColorG = g; c.readyColorB = b; c.readyColorA = a end
                  RefreshAll()
              end })
        y = y - h

        readyTextColorRow, h = W:DualRow(parent, y,
            { type="colorpicker", text="Ready Text Color",
              disabled=ITOff,
              getValue=function()
                  local c = IT()
                  return (c and c.readyTextColorR or 0.2), (c and c.readyTextColorG or 1), (c and c.readyTextColorB or 0.2)
              end,
              setValue=function(r, g, b)
                  local c = IT()
                  if c then c.readyTextColorR = r; c.readyTextColorG = g; c.readyTextColorB = b end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        cooldownColorRow, h = W:DualRow(parent, y,
            { type="slider", text="On-Cooldown Color Darken",
              min = 0, max = 100, step = 1,
              tooltip="Multiplies the class color while on cooldown -- lower = darker.",
              disabled=ITOff,
              getValue=function() local c = IT(); return (c and c.onCooldownColorMul or 0.7) * 100 end,
              setValue=function(v)
                  local c = IT(); if c then c.onCooldownColorMul = v / 100 end
                  RefreshAll()
              end },
            { type="slider", text="On-Cooldown Opacity",
              min = 0, max = 100, step = 1,
              disabled=ITOff,
              getValue=function() local c = IT(); return (c and c.onCooldownAlpha or 0.9) * 100 end,
              setValue=function(v)
                  local c = IT(); if c then c.onCooldownAlpha = v / 100 end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="colorpicker", text="No Data Bar Color",
              tooltip="Fill color for the placeholder bar shown while a party member's interrupt hasn't been detected yet.",
              disabled=ITOff,
              getValue=function()
                  local c = IT()
                  return (c and c.noAddonColorR or 0.2), (c and c.noAddonColorG or 0.2), (c and c.noAddonColorB or 0.2)
              end,
              setValue=function(r, g, b)
                  local c = IT()
                  if c then c.noAddonColorR = r; c.noAddonColorG = g; c.noAddonColorB = b end
                  RefreshAll()
              end },
            { type="slider", text="No Data Bar Opacity",
              min = 0, max = 100, step = 1,
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.noAddonOpacity or 80 end,
              setValue=function(v)
                  local c = IT(); if c then c.noAddonOpacity = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="colorpicker", text="No Data Text Color",
              disabled=ITOff,
              getValue=function()
                  local c = IT()
                  return (c and c.noAddonTextColorR or 0.6), (c and c.noAddonTextColorG or 0.6), (c and c.noAddonTextColorB or 0.6)
              end,
              setValue=function(r, g, b)
                  local c = IT()
                  if c then c.noAddonTextColorR = r; c.noAddonTextColorG = g; c.noAddonTextColorB = b end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        nameColorSection, h = W:SectionHeader(parent, "NAME COLOR", y); y = y - h

        nameColorReadyRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Name Color (Ready)",
              values = { custom = "Custom Color", class = "Class Color" },
              order  = { "custom", "class" },
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.nameColorReadyMode or "custom" end,
              setValue=function(v)
                  local c = IT(); if c then c.nameColorReadyMode = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="colorpicker", text="Ready Name Color",
              disabled=NameColorReadyCustomOff,
              getValue=function()
                  local c = IT()
                  return (c and c.nameColorReadyR or 1), (c and c.nameColorReadyG or 1), (c and c.nameColorReadyB or 1)
              end,
              setValue=function(r, g, b)
                  local c = IT()
                  if c then c.nameColorReadyR = r; c.nameColorReadyG = g; c.nameColorReadyB = b end
                  RefreshAll()
              end })
        y = y - h

        nameColorCooldownRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Name Color (On Cooldown)",
              values = { custom = "Custom Color", class = "Class Color" },
              order  = { "custom", "class" },
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.nameColorCooldownMode or "custom" end,
              setValue=function(v)
                  local c = IT(); if c then c.nameColorCooldownMode = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="colorpicker", text="On-Cooldown Name Color",
              disabled=NameColorCooldownCustomOff,
              getValue=function()
                  local c = IT()
                  return (c and c.nameColorCooldownR or 1), (c and c.nameColorCooldownG or 1), (c and c.nameColorCooldownB or 1)
              end,
              setValue=function(r, g, b)
                  local c = IT()
                  if c then c.nameColorCooldownR = r; c.nameColorCooldownG = g; c.nameColorCooldownB = b end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:SectionHeader(parent, "VISIBILITY", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Only In Instances",
              tooltip="Only show the window while inside a party/raid/scenario instance.",
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.onlyInInstances or false end,
              setValue=function(v)
                  local c = IT(); if c then c.onlyInInstances = v end
                  RefreshAll()
              end },
            { type="toggle", text="Hide In Dungeons",
              tooltip="Hides specifically while inside a 5-player dungeon.",
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.hideInDungeons or false end,
              setValue=function(v)
                  local c = IT(); if c then c.hideInDungeons = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="slider", text="Max Group Size To Show",
              min = 1, max = 5, step = 1,
              tooltip="Hides entirely once the group is bigger than this (i.e. in raids).",
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.maxGroupSizeToShow or 5 end,
              setValue=function(v)
                  local c = IT(); if c then c.maxGroupSizeToShow = v end
                  RefreshAll()
              end },
            { type="toggle", text="Show \"No Data\" Placeholders",
              tooltip="Shows a gray placeholder bar for party members whose interrupt hasn't been detected yet.",
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.showNoAddonPlaceholders ~= false end,
              setValue=function(v)
                  local c = IT(); if c then c.showNoAddonPlaceholders = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:SectionHeader(parent, "TALENT-BASED COOLDOWN ACCURACY (YOU ONLY)", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Enable Talent Adjustments",
              tooltip="Applies known talent-driven cooldown reductions/multipliers to your own tracked interrupt (Mage Quick Witted, Warrior Honed Reflexes, Evoker Interwoven Threads, Warlock Grimoire: Fel Ravager).",
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.enableTalentAdjustments ~= false end,
              setValue=function(v)
                  local c = IT(); if c then c.enableTalentAdjustments = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="DK: Mind Freeze CDR Talent",
              tooltip="Manual flag: you have a talent that shortens Mind Freeze's cooldown on a successful interrupt (not detectable automatically).",
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.dkMindFreezeCDRTalent or false end,
              setValue=function(v)
                  local c = IT(); if c then c.dkMindFreezeCDRTalent = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="slider", text="CDR Amount (sec)",
              min = 1, max = 15, step = 1,
              disabled=NotDkTalent,
              getValue=function() local c = IT(); return c and c.dkMindFreezeCDRAmount or 3 end,
              setValue=function(v)
                  local c = IT(); if c then c.dkMindFreezeCDRAmount = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:SectionHeader(parent, "PARTY SYNC", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Cross-Confirmation Sync",
              tooltip="Broadcasts your own kick over an addon message to the party and accepts the same from party members also running this addon, overwriting the local heuristic guess for them with their own reliable reading.",
              disabled=ITOff,
              getValue=function() local c = IT(); return c and c.syncEnabled ~= false end,
              setValue=function(v)
                  local c = IT(); if c then c.syncEnabled = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        -- Click-navigation targets for the preview above (see
        -- AttachInterruptTrackerPreviewOverlays / NavigateToInterruptTrackerSetting,
        -- defined near RefreshInterruptTrackerPreview). Stored in the outer
        -- closure rather than on `parent`, since the overlays need to attach
        -- as soon as BOTH this mapping AND the preview bars exist, and which
        -- of the two is ready first isn't guaranteed.
        interruptTrackerClickTargets = {
            icon             = { section = barAppearanceSection, target = iconPosRow },
            timeText         = { section = barAppearanceSection, target = textColorRow },
            timeTextReady    = { section = stateColorsSection,   target = readyTextColorRow },
            readyBar         = { section = stateColorsSection,   target = readyColorRow, slotSide = "right" },
            cooldownBar      = { section = stateColorsSection,   target = cooldownColorRow },
            nameTextReady    = { section = nameColorSection,     target = nameColorReadyRow },
            nameTextCooldown = { section = nameColorSection,     target = nameColorCooldownRow },
        }
        AttachInterruptTrackerPreviewOverlays()

        return math.abs(y)
    end

    ---------------------------------------------------------------------------
    --  Register with EllesmereUI sidebar
    ---------------------------------------------------------------------------
    -- RegisterModule whitelists callers by folder name (via debugstack), and
    -- "EllesmereUIVoidlol" isn't on that list -- a direct call is silently
    -- dropped, so modules[MODULE_KEY] never gets set and /evl + the sidebar
    -- button both stay dead. Route through a loadstring chunk instead: its
    -- chunkname isn't a file path, so the whitelist check (which only fires
    -- once it resolves a caller folder) never triggers.
    local MODULE_KEY = "EllesmereUIVoidlol"

    local function RegisterModuleExternal(config)
        local EUI = _G.EllesmereUI
        if not (EUI and EUI.RegisterModule) then return end

        _G.__EVL_pendingReg = { key = MODULE_KEY, config = config }
        local trampoline = loadstring([[
            local r = _G.__EVL_pendingReg
            if r and EllesmereUI and EllesmereUI.RegisterModule then
                EllesmereUI:RegisterModule(r.key, r.config)
            end
        ]], "EVL-register")
        local ok = trampoline and pcall(trampoline)
        _G.__EVL_pendingReg = nil

        if not ok then
            pcall(function() EUI:RegisterModule(MODULE_KEY, config) end)
        end
    end

    -- RegisterModule only wires up the pages; the sidebar row itself comes
    -- from a separate roster (ADDON_GROUPS/_addonInfoByFolder) that this
    -- addon was never added to. alwaysLoaded hides the per-addon power
    -- toggle, since this is a hard TOC dependency, not an optional module.
    local function InjectSidebar()
        local EUI = _G.EllesmereUI
        if not EUI then return end

        EUI._addonInfoByFolder = EUI._addonInfoByFolder or {}
        EUI._addonInfoByFolder[MODULE_KEY] = EUI._addonInfoByFolder[MODULE_KEY] or {
            folder       = MODULE_KEY,
            display      = "Voidlol",
            search_name  = "Voidlol EllesmereUIVoidlol",
            alwaysLoaded = true,
        }

        EUI.ADDON_GROUPS = EUI.ADDON_GROUPS or {}
        for _, group in ipairs(EUI.ADDON_GROUPS) do
            if group.key == "voidlol" then return end
        end
        table.insert(EUI.ADDON_GROUPS, 1, {
            key     = "voidlol",
            label   = "Voidlol",
            members = { MODULE_KEY },
        })
    end

    InjectSidebar()

    do
        local version = GetAddonVersion()
        local description = "Custom module for personal features and settings."
        if version then
            description = description .. "  |cff888888v" .. version .. "|r"
        end

        RegisterModuleExternal({
            title       = "Voidlol",
            description = description,
            -- PAGE_INTERRUPT_TRACKER deliberately excluded -- module force-
            -- disabled (see EllesmereUIVoidlol.lua ApplyAll/OnEnable), not
            -- reliable enough to expose right now. Left out of the nav list
            -- rather than deleted so it's a one-line revert to bring back.
            pages       = { PAGE_QOL, PAGE_TWEAKS, PAGE_QUICK_FOCUS, PAGE_COMBAT_TEXT, PAGE_CASTBAR, PAGE_HEALER_MANA },
            buildPage   = function(pageName, parent, yOffset)
                if pageName == PAGE_QOL          then return BuildQoLPage(pageName, parent, yOffset) end
                if pageName == PAGE_TWEAKS       then return BuildTweaksPage(pageName, parent, yOffset) end
                if pageName == PAGE_QUICK_FOCUS  then return BuildQuickFocusPage(pageName, parent, yOffset) end
                if pageName == PAGE_COMBAT_TEXT  then return BuildCombatTextPage(pageName, parent, yOffset) end
                if pageName == PAGE_CASTBAR      then return BuildCastbarPage(pageName, parent, yOffset) end
                if pageName == PAGE_HEALER_MANA  then return BuildHealerManaPage(pageName, parent, yOffset) end
                if pageName == PAGE_INTERRUPT_TRACKER then return BuildInterruptTrackerPage(pageName, parent, yOffset) end
            end,
            getHeaderBuilder = function(pageName)
                if pageName == PAGE_CASTBAR then
                    return castbarHeaderBuilder
                end
                if pageName == PAGE_HEALER_MANA then
                    return healerManaHeaderBuilder
                end
                if pageName == PAGE_INTERRUPT_TRACKER then
                    return interruptTrackerHeaderBuilder
                end
            end,
            onPageCacheRestore = function(pageName)
                activePreviewPage = pageName
                if pageName == PAGE_CASTBAR and castbarPreview and castbarPreview.Update then
                    -- Update() is UnitFrames' own generic refresh -- it knows
                    -- nothing about this page's dropdown-hiding/click-overlay
                    -- needs, so PolishCastbarPreview has to re-run by hand
                    -- every time this fires, not just on the original build.
                    -- Re-checked on a couple of staggered delays too, in
                    -- case Update()'s own refresh is itself deferred a frame
                    -- or two and would otherwise win the race and re-reveal
                    -- the dropdown after we already hid it.
                    castbarPreview:Update()
                    PolishCastbarPreview()
                    for _, delay in ipairs({ 0, 0.15, 0.3 }) do
                        C_Timer.After(delay, function()
                            if castbarPreview and castbarPreview.Update then
                                castbarPreview:Update()
                                ApplyCastbarPreviewStyle(castbarPreview)
                                PolishCastbarPreview()
                            end
                        end)
                    end
                end
                if pageName == PAGE_HEALER_MANA then
                    RefreshHealerManaPreview()
                end
                if pageName == PAGE_INTERRUPT_TRACKER then
                    RefreshInterruptTrackerPreview()
                end
            end,
            onReset = function()
                if _G._EVL_DB and _G._EVL_DB.ResetProfile then
                    _G._EVL_DB:ResetProfile()
                end
                EllesmereUI:InvalidatePageCache()
                RefreshAll()
            end,
        })
    end

    SLASH_EVL1 = "/evl"
    SlashCmdList.EVL = function()
        if InCombatLockdown and InCombatLockdown() then return end
        if EllesmereUI.Show then
            EllesmereUI:Show()
            C_Timer.After(0.1, function()
                EllesmereUI:SelectModule("EllesmereUIVoidlol")
            end)
        end
    end
end)
