-------------------------------------------------------------------------------
--  EllesmereUIVoidlol_QuickFocus.lua
--  Modifier + Click on a unit frame to set focus. Ported from the standalone
--  QuickFocus addon (github.com/voidlol/QuickFocus, MIT license, same author)
--  -- identical secure macro/attribute approach, wired into Voidlol's own DB
--  and settings tab instead of running as a separate addon.
--
--  Two mechanisms, same as upstream:
--   1) A global override-binding (modifier+button) that clicks a hidden
--      secure button running "/focus mouseover" -- works anywhere the mouse
--      is over a unit (frame, nameplate, 3D world model).
--   2) Per-frame secure attributes (<modifier>-type<N> = "focus") set
--      directly on known unit frames -- native SecureUnitButtonTemplate
--      click-casting, works even without the override binding.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EVL = ns.EVL

local focusButton
local eventsFrame
local pending = {}  -- frames whose attribute couldn't be set mid-combat
local HookAllFrames
-- Forward-declared because EnsureInit's event handler (defined above their
-- bodies) references them as upvalues; without these they would resolve to nil
-- globals and error when the PLAYER_REGEN_ENABLED / READY_CHECK events fire.
local HookFrame
local AnnounceFocusMarkOnReadyCheck

-------------------------------------------------------------------------------
--  DB helper
-------------------------------------------------------------------------------
local function DB()
    local d = EVL.DB and EVL.DB()
    return d and d.quickFocus
end

-------------------------------------------------------------------------------
--  Macro & Binding
-------------------------------------------------------------------------------
local function GetMacroText(cfg)
    local lines = { "/focus mouseover" }
    if cfg.setMark and cfg.markNumber and cfg.markNumber >= 1 and cfg.markNumber <= 8 then
        local markArg = "~" .. cfg.markNumber
        if cfg.safeMark then
            lines[#lines + 1] = "/tm [@focus,exists,help][@focus,exists,harm] " .. markArg
        else
            lines[#lines + 1] = "/tm [@focus,exists] " .. markArg
        end
    end
    return table.concat(lines, "\n")
end

local function UpdateBinding()
    local cfg = DB()
    if not focusButton or not cfg then return end
    focusButton:SetAttribute("macrotext", GetMacroText(cfg))
    ClearOverrideBindings(focusButton)
    if cfg.enabled ~= false then
        SetOverrideBindingClick(focusButton, true, cfg.modifier .. "-" .. cfg.button, "EllesmereUIVoidlol_QuickFocusButton")
    end
end

local function EnsureInit()
    if focusButton then return true end

    focusButton = CreateFrame("Button", "EllesmereUIVoidlol_QuickFocusButton", UIParent, "SecureActionButtonTemplate")
    focusButton:SetAttribute("type*", "macro")
    focusButton:RegisterForClicks("AnyDown", "AnyUp")

    eventsFrame = CreateFrame("Frame")
    eventsFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_ENABLED" then
            if next(pending) then
                for frame in next, pending do
                    HookFrame(frame)
                end
            end
            return
        end
        if event == "READY_CHECK" then
            AnnounceFocusMarkOnReadyCheck()
            return
        end
        HookAllFrames()
    end)

    return true
end

local function EnableEvents()
    if not eventsFrame then return end
    eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventsFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventsFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventsFrame:RegisterEvent("READY_CHECK")
end

local function DisableEvents()
    if not eventsFrame then return end
    eventsFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
    eventsFrame:UnregisterEvent("ZONE_CHANGED_NEW_AREA")
    eventsFrame:UnregisterEvent("GROUP_ROSTER_UPDATE")
    eventsFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
    eventsFrame:UnregisterEvent("READY_CHECK")
end

-------------------------------------------------------------------------------
--  Frame hooking
-------------------------------------------------------------------------------
HookFrame = function(frame)
    if not frame or frame.evlQuickFocusHooked then return end
    if frame.IsForbidden and frame:IsForbidden() then return end
    local cfg = DB()
    if not cfg then return end
    if not InCombatLockdown() then
        frame:SetAttribute(cfg.modifier .. "-type" .. strsub(cfg.button, 7, 7), "focus")
        frame.evlQuickFocusHooked = true
        pending[frame] = nil
    else
        pending[frame] = true
    end
end

-- IsForbidden() doesn't reliably catch every forbidden descendant while
-- walking CompactRaidFrameContainer/ERF trees (12.1 regression) -- pcall
-- every call that can hard-error with "Attempt to access forbidden object"
-- instead of trusting the pre-check alone.
local function HookChildren(frame)
    if not frame then return end
    if frame.IsForbidden and frame:IsForbidden() then return end

    if frame.GetAttribute then
        local ok, hasUnit = pcall(frame.GetAttribute, frame, "unit")
        if ok and hasUnit then
            HookFrame(frame)
        end
    end

    if not frame.GetNumChildren then return end
    local ok, numChildren = pcall(frame.GetNumChildren, frame)
    if not ok or not numChildren or numChildren == 0 then return end

    local ok2, children = pcall(function() return { frame:GetChildren() } end)
    if not ok2 then return end
    for i = 1, numChildren do
        HookChildren(children[i])
    end
end

local function HookByName(name)
    local f = _G[name]
    if f then HookFrame(f) end
end

-- Bounded 2-level walk (container -> group -> member) for Blizzard's own
-- CompactRaidFrameContainer, mirroring how ElvUI_WindTools's QuickFocus
-- module walks group headers -- checking "unit" at each level instead of
-- recursing arbitrarily deep into a tree we don't own. Unlike ERF headers
-- (our own frames, never forbidden), Blizzard's compact-frame internals can
-- contain forbidden descendants (auras, threat/role icons, etc.), so this
-- avoids ever descending into them instead of just catching the error.
local function TryHookIfUnit(frame)
    if not frame or not frame.GetAttribute then return false end
    local ok, hasUnit = pcall(frame.GetAttribute, frame, "unit")
    if ok and hasUnit then
        HookFrame(frame)
        return true
    end
    return false
end

local function GetChildrenSafe(frame)
    if not frame or not frame.GetNumChildren then return nil end
    local ok, numChildren = pcall(frame.GetNumChildren, frame)
    if not ok or not numChildren or numChildren == 0 then return nil end
    local ok2, children = pcall(function() return { frame:GetChildren() } end)
    if not ok2 then return nil end
    return children, numChildren
end

local function HookCompactRaidFrameContainer(name)
    local container = _G[name]
    if not container then return end
    if container.IsForbidden and container:IsForbidden() then return end

    local groups, numGroups = GetChildrenSafe(container)
    if not groups then return end
    for i = 1, numGroups do
        local group = groups[i]
        if group and not (group.IsForbidden and group:IsForbidden()) then
            if not TryHookIfUnit(group) then
                local members, numMembers = GetChildrenSafe(group)
                if members then
                    for j = 1, numMembers do
                        local member = members[j]
                        if member and not (member.IsForbidden and member:IsForbidden()) then
                            TryHookIfUnit(member)
                        end
                    end
                end
            end
        end
    end
end

local function HookChildrenByName(name)
    local f = _G[name]
    if f then HookChildren(f) end
end

-------------------------------------------------------------------------------
--  Known frame lists -- EllesmereUI's own frames first, Blizzard default as
--  a fallback (harmless no-op via the nil-guarded HookByName if absent).
-------------------------------------------------------------------------------
local EUI_UNITFRAME_NAMES = {
    "EllesmereUIUnitFrames_Player",
    "EllesmereUIUnitFrames_Target",
    "EllesmereUIUnitFrames_Focus",
    "EllesmereUIUnitFrames_Pet",
    "EllesmereUIUnitFrames_TargetTarget",
    "EllesmereUIUnitFrames_FocusTarget",
    "EllesmereUIUnitFrames_Boss1",
    "EllesmereUIUnitFrames_Boss2",
    "EllesmereUIUnitFrames_Boss3",
    "EllesmereUIUnitFrames_Boss4",
    "EllesmereUIUnitFrames_Boss5",
}

local EUI_RAIDFRAME_HEADER_NAMES = {
    "ERFPartyHeader",
    "ERFFlatHeader",
    "ERFGroupHeader1", "ERFGroupHeader2", "ERFGroupHeader3", "ERFGroupHeader4",
    "ERFGroupHeader5", "ERFGroupHeader6", "ERFGroupHeader7", "ERFGroupHeader8",
}

local EUI_RAIDFRAME_BUTTON_NAMES = {
    "ERFPartySelfButton",
    "ERFFriendlyBoss1", "ERFFriendlyBoss2", "ERFFriendlyBoss3",
    "ERFFriendlyBoss4", "ERFFriendlyBoss5",
}
for i = 1, 10 do
    EUI_RAIDFRAME_BUTTON_NAMES[#EUI_RAIDFRAME_BUTTON_NAMES + 1] = "ERFExtraFrame" .. i
end

local BLIZZARD_SINGLE_FRAME_NAMES = {
    "PlayerFrame", "TargetFrame", "FocusFrame", "PetFrame",
    "TargetTargetFrame", "FocusTargetFrame",
}

HookAllFrames = function()
    local cfg = DB()
    if not cfg or cfg.enabled == false then return end

    for _, name in ipairs(EUI_UNITFRAME_NAMES) do HookByName(name) end
    for _, name in ipairs(EUI_RAIDFRAME_HEADER_NAMES) do HookChildrenByName(name) end
    for _, name in ipairs(EUI_RAIDFRAME_BUTTON_NAMES) do HookByName(name) end

    for _, name in ipairs(BLIZZARD_SINGLE_FRAME_NAMES) do HookByName(name) end
    for i = 1, 5 do HookByName("PartyMemberFrame" .. i) end
    HookCompactRaidFrameContainer("CompactRaidFrameContainer")
end

-------------------------------------------------------------------------------
--  Ready Check announcement: "My focus mark is {rtN}" to party/raid chat
-------------------------------------------------------------------------------
local function GetAnnounceChannel(cfg)
    if IsInRaid() then
        if cfg.announceInRaid == false then return nil end
        return "RAID"
    end
    if IsInGroup() then
        if cfg.announceInParty == false then return nil end
        return "PARTY"
    end
    return nil
end

AnnounceFocusMarkOnReadyCheck = function()
    local cfg = DB()
    if not cfg or not cfg.announceFocusMarkOnReadyCheck then return end
    if not cfg.setMark or not cfg.markNumber then return end
    local channel = GetAnnounceChannel(cfg)
    if not channel then return end
    SendChatMessage("My focus mark is {rt" .. cfg.markNumber .. "}", channel)
end

-------------------------------------------------------------------------------
--  Apply (called on settings change / login)
-------------------------------------------------------------------------------
local function ApplyAll()
    local cfg = DB()
    if not cfg then return end
    if cfg.enabled == false then
        if focusButton then
            ClearOverrideBindings(focusButton)
        end
        DisableEvents()
        return
    end

    EnsureInit()
    EnableEvents()
    UpdateBinding()
    HookAllFrames()
end
EVL.ApplyQuickFocus = ApplyAll

-------------------------------------------------------------------------------
--  Bootstrap
-------------------------------------------------------------------------------
function EVL.InitQuickFocus()
    EnsureInit()
    ApplyAll()
end
