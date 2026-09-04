-------------------------------------------------------------------------------
--  EllesmereUIVoidlol_ImportExport.lua
--  Settings import/export, surfaced under the Import/Export options tab
--  (EUI_Voidlol_Options.lua). Two layers:
--
--    1. A per-tab manifest (get/merge) describing exactly which DB keys each
--       options tab owns, plus Export/Preview/Apply functions built on top
--       of LibEUIExport-1.0 (Libs/LibEUIExport-1.0). No UI in this half.
--    2. A small custom checklist popup (EllesmereUI exposes no public
--       multi-checkbox popup, only ShowConfirmPopup's single optional one)
--       plus two flow functions wiring it together with EllesmereUI's own
--       public ShowCopyPopup / ShowImportPopup / ShowInfoPopup.
--
--  QoL and Tweaks are two options TABS but share ONE underlying DB table
--  (EVL.DB().qol -- EllesmereUIVoidlol_Tweaks.lua's own DB() reads the same
--  table), so they can't be told apart by "the whole subtree" the way every
--  other tab can -- each needs an explicit own-fields list instead.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EVL = ns.EVL

local function DB() return EVL.DB() end

-- Distinguishes this addon's export strings from any other LibEUIExport-1.0
-- user's (the library is meant to be shared) -- PreviewImportString rejects
-- anything else with a clear message instead of silently misapplying it.
local EXPORT_TYPE = "EllesmereUIVoidlolSettings"

-------------------------------------------------------------------------------
--  Generic table helpers
-------------------------------------------------------------------------------
local function DeepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = DeepCopy(v) end
    return out
end

-- Copies every key present in src onto dst, recursing into sub-tables.
-- Never touches a dst key absent from src -- this is what makes "leave
-- unselected/absent settings alone" on import a natural consequence of only
-- ever calling this with the imported data, never the other way around.
local function DeepMergeInto(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            DeepMergeInto(dst[k], v)
        else
            dst[k] = v
        end
    end
end

local function ExtractFields(t, fieldList)
    if not t then return nil end
    local out = {}
    for i = 1, #fieldList do
        local k = fieldList[i]
        out[k] = t[k]
    end
    return out
end

-------------------------------------------------------------------------------
--  Tab manifest
--  order here is display order in both the export and import checklists.
-------------------------------------------------------------------------------
local QOL_OWN_FIELDS = { "actualDragonridingVisibility", "suppressAutoPlayed" }
local TWEAKS_OWN_FIELDS = { "runesSpecColored", "resourceBarBlockStyle", "buffBorderBlack", "mirrorCdmCooldownsVisibilityToBars" }

-- A tab whose data is simply the whole cfg[id] subtree, verbatim.
local function SimpleTab(id, label)
    return {
        id = id, label = label,
        get = function(cfg) return DeepCopy(cfg[id]) end,
        merge = function(cfg, data)
            if not data then return end
            if type(cfg[id]) ~= "table" then cfg[id] = {} end
            DeepMergeInto(cfg[id], data)
        end,
    }
end

local TABS = {
    { id = "qol", label = "QoL",
      get = function(cfg)
          local q = cfg.qol
          if not q then return nil end
          local out = ExtractFields(q, QOL_OWN_FIELDS)
          out.statusBar = DeepCopy(q.statusBar)
          return out
      end,
      merge = function(cfg, data)
          if not (cfg.qol and data) then return end
          DeepMergeInto(cfg.qol, data)
      end },
    { id = "tweaks", label = "Tweaks",
      get = function(cfg) return ExtractFields(cfg.qol, TWEAKS_OWN_FIELDS) end,
      merge = function(cfg, data)
          if not (cfg.qol and data) then return end
          DeepMergeInto(cfg.qol, data)
      end },
    SimpleTab("quickFocus", "Quick Focus"),
    SimpleTab("combatText", "Combat Text"),
    SimpleTab("castbar", "Target Castbar"),
    SimpleTab("healerMana", "Healer Mana"),
}

EVL.ImportExportTabs = TABS

-------------------------------------------------------------------------------
--  Export / Import (no UI)
-------------------------------------------------------------------------------
local function GetLib()
    return LibStub and LibStub("LibEUIExport-1.0", true)
end

-- selectedIds = { [tabId] = true, ... }. Returns str, or nil, err.
function EVL.ExportSelectedTabs(selectedIds)
    local Lib = GetLib()
    if not Lib then return nil, "LibEUIExport-1.0 is not available" end
    local cfg = DB()
    if not cfg then return nil, "settings are not available" end

    local data = {}
    local any = false
    for i = 1, #TABS do
        local tab = TABS[i]
        if selectedIds and selectedIds[tab.id] then
            local tabData = tab.get(cfg)
            if tabData then
                data[tab.id] = tabData
                any = true
            end
        end
    end
    if not any then return nil, "Select at least one tab to export." end

    local ok, str = pcall(function() return Lib:Export(ADDON_NAME, EXPORT_TYPE, data) end)
    if not ok then return nil, tostring(str) end
    return str
end

-- Parses an import string without touching the DB. Returns
-- { name, tabIds = {id, ...}, data = {[id]=tabData} } (tabIds only ever
-- contains ids this version of the addon actually knows about), or nil, err.
function EVL.PreviewImportString(inputStr)
    local Lib = GetLib()
    if not Lib then return nil, "LibEUIExport-1.0 is not available" end

    local result, err = Lib:Import(inputStr)
    if not result then return nil, err or "Invalid import string." end
    if result.type ~= EXPORT_TYPE then
        return nil, "This is not an EllesmereUIVoidlol settings string."
    end
    if type(result.data) ~= "table" then
        return nil, "Malformed export data."
    end

    local tabIds = {}
    for i = 1, #TABS do
        local tab = TABS[i]
        if result.data[tab.id] ~= nil then
            tabIds[#tabIds + 1] = tab.id
        end
    end
    if #tabIds == 0 then
        return nil, "No known settings found in this string."
    end

    return { name = result.name, tabIds = tabIds, data = result.data }
end

-- Applies only selectedIds (= { [tabId] = true, ... }) from a previewResult
-- (see PreviewImportString) onto the live DB. Tabs not in selectedIds, and
-- everything outside the tabs present in the import, are left untouched.
-- Returns the number of tabs actually applied.
function EVL.ApplyImportedTabs(previewResult, selectedIds)
    local cfg = DB()
    if not (cfg and previewResult and previewResult.data) then return 0 end
    local applied = 0
    for i = 1, #TABS do
        local tab = TABS[i]
        if selectedIds and selectedIds[tab.id] and previewResult.data[tab.id] ~= nil then
            tab.merge(cfg, previewResult.data[tab.id])
            applied = applied + 1
        end
    end
    if applied > 0 and EVL.ApplyAll then EVL.ApplyAll() end
    return applied
end

-------------------------------------------------------------------------------
--  Checklist popup (generic: entries = { {id=, label=}, ... })
--  Mirrors EllesmereUI_Profiles.lua's own BuildStringPopup conventions
--  (dimmer, MakeBorder, MakeStyledButton, WB_COLOURS/RB_COLOURS, Escape /
--  click-outside to cancel) so it reads as part of the same UI family, but
--  is built locally: EllesmereUI has no public equivalent of its own (only
--  ShowConfirmPopup's single optional checkbox).
-------------------------------------------------------------------------------
local function ShowChecklistPopup(title, subtitle, entries, initialChecked, onConfirm, onCancel, confirmLabel)
    local EUI = _G.EllesmereUI
    if not EUI then return end

    local ROW_H, PAD_TOP, PAD_BOTTOM, POPUP_W = 24, 66, 60, 340
    local popupH = PAD_TOP + PAD_BOTTOM + (#entries * ROW_H)

    local dimmer = CreateFrame("Frame", nil, UIParent)
    dimmer:SetFrameStrata("FULLSCREEN_DIALOG")
    dimmer:SetAllPoints(UIParent)
    dimmer:EnableMouse(true)
    dimmer:EnableMouseWheel(true)
    dimmer:SetScript("OnMouseWheel", function() end)
    local dimTex = dimmer:CreateTexture(nil, "BACKGROUND")
    dimTex:SetAllPoints()
    dimTex:SetColorTexture(0, 0, 0, 0.25)

    local popup = CreateFrame("Frame", nil, dimmer)
    popup:SetSize(POPUP_W, popupH)
    popup:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetFrameLevel(dimmer:GetFrameLevel() + 10)
    popup:EnableMouse(true)
    local bg = popup:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.08, 0.10, 1)
    EUI.MakeBorder(popup, 1, 1, 1, 0.15, EUI.PanelPP)

    local titleFS = EUI.MakeFont(popup, 15, "", 1, 1, 1)
    titleFS:SetPoint("TOP", popup, "TOP", 0, -20)
    titleFS:SetText(EUI.L(title))

    local subFS = EUI.MakeFont(popup, 11, "", 1, 1, 1)
    subFS:SetAlpha(0.45)
    subFS:SetPoint("TOP", titleFS, "BOTTOM", 0, -4)
    subFS:SetText(EUI.L(subtitle or ""))

    local checked = {}
    local prevRow
    for i, entry in ipairs(entries) do
        local row = CreateFrame("Button", nil, popup)
        row:SetSize(POPUP_W - 40, ROW_H)
        if prevRow then
            row:SetPoint("TOP", prevRow, "BOTTOM", 0, 0)
        else
            row:SetPoint("TOP", subFS, "BOTTOM", 0, -10)
        end
        row:SetFrameLevel(popup:GetFrameLevel() + 1)

        local box = CreateFrame("Frame", nil, row)
        box:SetSize(16, 16)
        box:SetPoint("LEFT", row, "LEFT", 4, 0)
        local boxBg = EUI.SolidTex(box, "BACKGROUND", 1, 1, 1, 0.04)
        boxBg:SetAllPoints()
        EUI.MakeBorder(box, 1, 1, 1, 0.25)
        local check = EUI.SolidTex(box, "ARTWORK", 1, 1, 1, 1)
        check:SetPoint("TOPLEFT", 3, -3)
        check:SetPoint("BOTTOMRIGHT", -3, 3)

        local label = EUI.MakeFont(row, 12, nil, 1, 1, 1, 0.9)
        label:SetPoint("LEFT", box, "RIGHT", 8, 0)
        label:SetText(EUI.L(entry.label))

        local isChecked = (initialChecked and initialChecked[entry.id]) or false
        checked[entry.id] = isChecked
        check:SetShown(isChecked)

        row:SetScript("OnClick", function()
            checked[entry.id] = not checked[entry.id]
            check:SetShown(checked[entry.id])
        end)

        prevRow = row
    end

    local confirmBtn = CreateFrame("Button", nil, popup)
    confirmBtn:SetSize(120, 26)
    confirmBtn:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -4, 14)
    confirmBtn:SetFrameLevel(popup:GetFrameLevel() + 2)
    EUI.MakeStyledButton(confirmBtn, confirmLabel or "OK", 11, EUI.WB_COLOURS, function()
        dimmer:Hide()
        if onConfirm then onConfirm(checked) end
    end)

    local cancelBtn = CreateFrame("Button", nil, popup)
    cancelBtn:SetSize(120, 26)
    cancelBtn:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 4, 14)
    cancelBtn:SetFrameLevel(popup:GetFrameLevel() + 2)
    EUI.MakeStyledButton(cancelBtn, "Cancel", 11, EUI.RB_COLOURS, function()
        dimmer:Hide()
        if onCancel then onCancel() end
    end)

    dimmer:SetScript("OnMouseDown", function()
        if not popup:IsMouseOver() then
            dimmer:Hide()
            if onCancel then onCancel() end
        end
    end)

    popup:EnableKeyboard(true)
    popup:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            dimmer:Hide()
            if onCancel then onCancel() end
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    dimmer:Show()
end

-------------------------------------------------------------------------------
--  Flows
-------------------------------------------------------------------------------

-- Export: checklist (all checked by default) -> ExportSelectedTabs ->
-- EllesmereUI's own read-only ShowCopyPopup for the resulting string.
function EVL.ShowExportFlow()
    local EUI = _G.EllesmereUI
    if not EUI then return end

    local entries, initialChecked = {}, {}
    for i = 1, #TABS do
        entries[i] = { id = TABS[i].id, label = TABS[i].label }
        initialChecked[TABS[i].id] = true
    end

    ShowChecklistPopup("Export Settings", "Choose what to export", entries, initialChecked,
        function(selected)
            local str, err = EVL.ExportSelectedTabs(selected)
            if not str then
                EUI:ShowInfoPopup({ title = "Export Failed", content = err or "Unknown error" })
                return
            end
            EUI:ShowCopyPopup("Export Settings", "Copy the string below and share it", str)
        end)
end

-- Import: EllesmereUI's own ShowImportPopup (paste box) -> PreviewImportString
-- -> checklist restricted to tabs actually present in the string (all
-- checked by default) -> ApplyImportedTabs.
function EVL.ShowImportFlow()
    local EUI = _G.EllesmereUI
    if not EUI then return end

    EUI:ShowImportPopup(function(str)
        local preview, err = EVL.PreviewImportString(str)
        if not preview then
            EUI:ShowInfoPopup({ title = "Import Failed", content = err or "Invalid import string." })
            return
        end

        local presentIds = {}
        for _, id in ipairs(preview.tabIds) do presentIds[id] = true end

        local entries, initialChecked = {}, {}
        for i = 1, #TABS do
            local tab = TABS[i]
            if presentIds[tab.id] then
                entries[#entries + 1] = { id = tab.id, label = tab.label }
                initialChecked[tab.id] = true
            end
        end

        ShowChecklistPopup("Import Settings", "Choose what to apply", entries, initialChecked,
            function(selected)
                local applied = EVL.ApplyImportedTabs(preview, selected)
                EUI:ShowInfoPopup({
                    title = "Import",
                    content = (applied > 0) and "Selected settings have been applied." or "Nothing selected -- no changes made.",
                })
            end)
    end, "Import Settings", "Paste an EllesmereUIVoidlol settings string below")
end
