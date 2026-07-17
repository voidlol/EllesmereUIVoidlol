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

local PAGE_QOL          = "QoL"
local PAGE_QUICK_FOCUS  = "Quick Focus"
local PAGE_COMBAT_TEXT  = "Combat Text"
local PAGE_CASTBAR      = "Target Castbar"
local PAGE_HEALER_MANA  = "Healer Mana"

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
    local function QF()      local d = DB(); return d and d.quickFocus end
    local function CT(key)   local d = DB(); local ct = d and d.combatText; return ct and ct[key] end
    local function Castbar() local d = DB(); return d and d.castbar end
    local function HealerMana() local d = DB(); return d and d.healerMana end
    local castbarPreview
    local castbarHeaderBuilder
    local healerManaPreviewRow
    local healerManaHeaderBuilder

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

    -- Restyles the standalone Healer Mana preview row (independent of the
    -- Enabled toggle / Unlock Mode) with a random sample healer, so the
    -- options page always shows a live sample as settings change and actually
    -- demonstrates the range (spec/icon, name, and mana% gradient) rather than
    -- always looking identical. Also re-asserts Show() on the row's holder:
    -- reported symptom was the preview vanishing after leaving a dungeon group
    -- (i.e. after a loading screen) until /reloadui -- a PLAYER_ENTERING_WORLD-
    -- driven re-show below is the standard remedy for a dynamically-created
    -- frame going stale across a loading screen.
    local function RefreshHealerManaPreview()
        if not healerManaPreviewRow or not EVL.HealerMana_StylePreviewRow then return end
        local holder = healerManaPreviewRow:GetParent()
        if holder then holder:Show() end
        local specID, name = 257, "Thunderstrikeus"
        if EVL.HealerMana_GetRandomPreviewSample then
            specID, name = EVL.HealerMana_GetRandomPreviewSample()
        end
        EVL.HealerMana_StylePreviewRow(healerManaPreviewRow, specID, name, math.random(1, 100))
    end

    local healerManaPreviewHealFrame = CreateFrame("Frame")
    healerManaPreviewHealFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    healerManaPreviewHealFrame:SetScript("OnEvent", RefreshHealerManaPreview)

    local function RefreshAll()
        if EVL.ApplyAll then EVL.ApplyAll() end
        if castbarPreview and castbarPreview.Update then
            castbarPreview:Update()
            ApplyCastbarPreviewStyle(castbarPreview)
        end
        RefreshHealerManaPreview()
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
            { type="toggle", text="Set Raid Marker on Focus",
              getValue=function() local c = QF(); return c and c.setMark or false end,
              setValue=function(v)
                  local c = QF(); if c then c.setMark = v end
                  RefreshAll()
                  RefreshWidgets()
              end })
        y = y - h

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
        _, h = W:DualRow(parent, y,
            { type="dropdown", text="Marker",
              values=markValues, order=markOrder,
              disabled=MarkOff,
              getValue=function() local c = QF(); return c and c.markNumber or 3 end,
              setValue=function(v)
                  local c = QF(); if c then c.markNumber = v end
                  RefreshAll()
              end },
            { type="toggle", text="Safe Mark",
              tooltip="Only sets the marker on castable targets (help/harm), preventing 'invalid target' errors.",
              disabled=MarkOff,
              getValue=function() local c = QF(); return c and c.safeMark or false end,
              setValue=function(v)
                  local c = QF(); if c then c.safeMark = v end
                  RefreshAll()
              end })
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
                { type="label", text="" })
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
    local function BuildCastbarHeaderPreview(hdr, hdrW)
        local modules = EllesmereUI and EllesmereUI._modules
        local ufConfig = modules and modules.EllesmereUIUnitFrames
        local ufBuilder = ufConfig and ufConfig.getHeaderBuilder and ufConfig.getHeaderBuilder("Main Frames")
        local totalH

        castbarPreview = nil

        if not ufBuilder then
            local fontPath = (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
            local fs = hdr._evlFallbackFS or hdr:CreateFontString(nil, "OVERLAY")
            hdr._evlFallbackFS = fs
            fs:SetFont(fontPath, 13, "")
            fs:SetTextColor(1, 1, 1, 0.65)
            fs:ClearAllPoints()
            fs:SetPoint("TOP", hdr, "TOP", 0, -28)
            fs:SetText("Open Unit Frames once, then reopen this page to initialize the target preview.")
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
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:SectionHeader(parent, "ICON", y); y = y - h

        local function IconNotDetached() local c = Castbar(); return not (c and c.detachIcon) end
        local function IconTextOff() local c = Castbar(); return not (c and c.showUninterruptibleText) end

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Detach Icon",
              tooltip="Moves the cast icon off the castbar so it can be positioned independently.",
              getValue=function() local c = Castbar(); return c and c.detachIcon or false end,
              setValue=function(v)
                  local c = Castbar(); if c then c.detachIcon = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="slider", text="Icon Size",
              min = 16, max = 64, step = 1,
              getValue=function() local c = Castbar(); return c and c.iconSize or 32 end,
              setValue=function(v)
                  local c = Castbar(); if c then c.iconSize = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="slider", text="Icon Border Width",
              min = 0, max = 8, step = 1,
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
              getValue=function() local c = Castbar(); return c and c.desaturateUninterruptible ~= false end,
              setValue=function(v)
                  local c = Castbar(); if c then c.desaturateUninterruptible = v end
                  RefreshAll()
              end },
            { type="toggle", text="Text Over Icon on Uninterruptible",
              tooltip="Overlays text on the cast icon when the cast cannot be interrupted.",
              getValue=function() local c = Castbar(); return c and c.showUninterruptibleText ~= false end,
              setValue=function(v)
                  local c = Castbar(); if c then c.showUninterruptibleText = v end
                  RefreshAll()
                  RefreshWidgets()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
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

        _, h = W:SectionHeader(parent, "BAR", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Overlay on Target Frame",
              tooltip="Makes the castbar itself transparent and overlays it on the target frame, leaving only text and spark visible.",
              getValue=function() local c = Castbar(); return c and c.overlayMode or false end,
              setValue=function(v)
                  local c = Castbar(); if c then c.overlayMode = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        return math.abs(y)
    end

    ---------------------------------------------------------------------------
    --  Healer Mana page
    ---------------------------------------------------------------------------
    -- Standalone preview row -- independent of Enabled/Unlock Mode, always
    -- shows a live sample as settings change (EVL.HealerMana_StylePreviewRow).
    -- Built via the HEADER mechanism (like BuildCastbarHeaderPreview), not
    -- buildPage's content area: getHeaderBuilder's function is invoked fresh
    -- on every page display (including a cached-page revisit), whereas
    -- buildPage only runs once per session for an already-built page. A
    -- previous content-area version of this preview went permanently
    -- invisible after the underlying page content frame got recycled (no
    -- error, no fix from Show()/SetPoint/tab-switching, only /reloadui) --
    -- because SetPoint alone never re-parents a frame, so a holder created
    -- against a stale "parent" argument stays a child of that stale, no
    -- longer relevant frame forever. Re-parenting here (SetParent(hdr)) on
    -- every invocation fixes that at the root instead of just papering over it.
    local function BuildHealerManaHeaderPreview(hdr, hdrW)
        if not healerManaPreviewRow and EVL.HealerMana_CreatePreviewRow then
            local holder = CreateFrame("Frame", nil, hdr)
            holder:SetSize(280, 40)
            healerManaPreviewRow = EVL.HealerMana_CreatePreviewRow(holder)
            healerManaPreviewRow:ClearAllPoints()
            healerManaPreviewRow:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        end
        if healerManaPreviewRow then
            local holder = healerManaPreviewRow:GetParent()
            holder:SetParent(hdr)
            holder:ClearAllPoints()
            holder:SetPoint("TOP", hdr, "TOP", 0, -20)
            RefreshHealerManaPreview()
        end
        return 88
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

        local function RaidOff() local c = HealerMana(); return not (c and c.showInRaid) end
        local function IconOff() local c = HealerMana(); return c and c.showIcon == false end

        _, h = W:SectionHeader(parent, "GENERAL", y); y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Enabled",
              tooltip="Shows mana% for your group's/raid's healers. Open EllesmereUI Unlock Mode to preview and position the Party/Raid frames.",
              getValue=function() local c = HealerMana(); return c and c.enabled or false end,
              setValue=function(v)
                  local c = HealerMana(); if c then c.enabled = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="toggle", text="Show in Party",
              getValue=function() local c = HealerMana(); return c and c.showInParty ~= false end,
              setValue=function(v)
                  local c = HealerMana(); if c then c.showInParty = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Show in Raid",
              getValue=function() local c = HealerMana(); return c and c.showInRaid ~= false end,
              setValue=function(v)
                  local c = HealerMana(); if c then c.showInRaid = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="dropdown", text="Raid Grow Direction",
              values = { VERTICAL = "Vertical", HORIZONTAL = "Horizontal" },
              order  = { "VERTICAL", "HORIZONTAL" },
              disabled = RaidOff,
              getValue=function() local c = HealerMana(); return c and c.raidGrowDirection or "VERTICAL" end,
              setValue=function(v)
                  local c = HealerMana(); if c then c.raidGrowDirection = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Show Icon",
              tooltip="Shows the healer's spec icon next to their name. Off collapses the row to text only.",
              getValue=function() local c = HealerMana(); return c and c.showIcon ~= false end,
              setValue=function(v)
                  local c = HealerMana(); if c then c.showIcon = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="slider", text="Icon Size",
              min = 12, max = 72, step = 1,
              disabled=IconOff,
              getValue=function() local c = HealerMana(); return c and c.iconSize or 24 end,
              setValue=function(v)
                  local c = HealerMana(); if c then c.iconSize = v end
                  RefreshAll()
              end })
        y = y - h

        _, h = W:DualRow(parent, y,
            { type="slider", text="Max Name Length",
              min = 0, max = 10, step = 1,
              tooltip="Truncates each healer's name to this many characters. 0 = unlimited.",
              getValue=function() local c = HealerMana(); return c and c.nameMaxLength or 0 end,
              setValue=function(v)
                  local c = HealerMana(); if c then c.nameMaxLength = v end
                  RefreshAll()
              end },
            { type="label", text="" })
        y = y - h

        _, h = W:SectionHeader(parent, "FONT", y); y = y - h

        local fontValues, fontOrder = EllesmereUI.BuildFontDropdownData()
        _, h = W:DualRow(parent, y,
            { type="dropdown", text="Font",
              values = fontValues, order = fontOrder,
              getValue=function() local c = HealerMana(); return c and c.fontFace or "__global" end,
              setValue=function(v)
                  local c = HealerMana(); if c then c.fontFace = v end
                  RefreshAll()
              end },
            { type="slider", text="Font Size",
              min = 8, max = 32, step = 1,
              getValue=function() local c = HealerMana(); return c and c.fontSize or 12 end,
              setValue=function(v)
                  local c = HealerMana(); if c then c.fontSize = v end
                  RefreshAll()
              end })
        y = y - h

        local function ManaColorOff() local c = HealerMana(); return not (c and c.useCustomManaColor) end

        _, h = W:DualRow(parent, y,
            { type="toggle", text="Use Custom Mana Color",
              tooltip="When off, mana% text color is a red (0%) to green (100%) gradient based on the healer's current mana.",
              getValue=function() local c = HealerMana(); return c and c.useCustomManaColor or false end,
              setValue=function(v)
                  local c = HealerMana(); if c then c.useCustomManaColor = v end
                  RefreshAll()
                  RefreshWidgets()
              end },
            { type="colorpicker", text="Mana Text Color",
              disabled = ManaColorOff,
              getValue=function()
                  local c = HealerMana()
                  return (c and c.manaColorR or 1), (c and c.manaColorG or 1), (c and c.manaColorB or 1)
              end,
              setValue=function(r, g, b)
                  local c = HealerMana()
                  if c then c.manaColorR = r; c.manaColorG = g; c.manaColorB = b end
                  RefreshAll()
              end })
        y = y - h

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
        RegisterModuleExternal({
            title       = "Voidlol",
            description = "Custom module for personal features and settings.",
            pages       = { PAGE_QOL, PAGE_QUICK_FOCUS, PAGE_COMBAT_TEXT, PAGE_CASTBAR, PAGE_HEALER_MANA },
            buildPage   = function(pageName, parent, yOffset)
                if pageName == PAGE_QOL          then return BuildQoLPage(pageName, parent, yOffset) end
                if pageName == PAGE_QUICK_FOCUS  then return BuildQuickFocusPage(pageName, parent, yOffset) end
                if pageName == PAGE_COMBAT_TEXT  then return BuildCombatTextPage(pageName, parent, yOffset) end
                if pageName == PAGE_CASTBAR      then return BuildCastbarPage(pageName, parent, yOffset) end
                if pageName == PAGE_HEALER_MANA  then return BuildHealerManaPage(pageName, parent, yOffset) end
            end,
            getHeaderBuilder = function(pageName)
                if pageName == PAGE_CASTBAR then
                    return castbarHeaderBuilder
                end
                if pageName == PAGE_HEALER_MANA then
                    return healerManaHeaderBuilder
                end
            end,
            onPageCacheRestore = function(pageName)
                if pageName == PAGE_CASTBAR and castbarPreview and castbarPreview.Update then
                    castbarPreview:Update()
                    C_Timer.After(0, function()
                        if castbarPreview and castbarPreview.Update then
                            castbarPreview:Update()
                            ApplyCastbarPreviewStyle(castbarPreview)
                        end
                    end)
                end
                if pageName == PAGE_HEALER_MANA then
                    RefreshHealerManaPreview()
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
