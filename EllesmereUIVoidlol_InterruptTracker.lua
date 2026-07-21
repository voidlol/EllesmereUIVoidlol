-------------------------------------------------------------------------------
--  EllesmereUIVoidlol_InterruptTracker.lua
--  Party interrupt-cooldown tracking: one status bar per party member (+ your
--  own), showing when their interrupt is on cooldown / ready. Ported from
--  InterruptTrackerReference.lua (a standalone reference build consolidated
--  from a separate addon's IT_Database/IT_Core/InterruptTrack files).
--
--  Detection: your own kick-cast is read directly off UNIT_SPELLCAST_SUCCEEDED
--  (100% reliable, spellID isn't tainted for the local unit) -- see
--  HandleOwnKick. Party members are REACTIVE ONLY: we never try to detect
--  their cast attempt (that required laundering a tainted spellID off their
--  UNIT_SPELLCAST_SUCCEEDED and guessing whether it was their kick vs any
--  other ability -- an earlier version did this via ResolveInterruptSpell/
--  HandlePartyCast/a taint-laundering slider hack, all removed). Instead a
--  teammate's bar is created and its cooldown started the instant their
--  interrupt is confirmed LANDED, via UNIT_SPELLCAST_INTERRUPTED/
--  _CHANNEL_STOP's `interruptedBy` GUID -- see CONFIRM HIT. This mirrors how
--  EXBoss's interrupt tracker handles teammates (reactive-only) and trades
--  away "cooldown counting down before it's confirmed" for a much smaller,
--  sturdier surface -- no tainted-spellID resolution, no extraKicks
--  bookkeeping, one clear responsibility per event. The raw `interruptedBy`
--  GUID is a secret value for anyone but yourself; UnitTokenFromGUID and
--  UnitNameFromGUID/UnitClassFromGUID ("blessed" display-only resolvers) let
--  us read WHO without ever touching the GUID itself, though their RETURN
--  VALUE can itself still be secret and must be re-checked (see CONFIRM
--  HIT) -- when it is, we just skip that hit, same limitation EXBoss has.
--  If a party member also runs this addon, their own kick reading is
--  broadcast over an addon message (chat type "PARTY") and overwrites the
--  local guess for that person -- see the SYNC section.
--
--  Deviations from the reference build:
--   - Every user-facing tunable in the reference's local `S` settings table
--     now lives in SavedVariables (DB()/cfg below) and has an Options UI
--     page (EUI_Voidlol_Options.lua). Purely technical constants (addon-
--     message prefixes, inspect retry schedule, hit/miss confirm delay)
--     stay hardcoded near the top of this file.
--   - The reference attributed a landed interrupt to a party member by
--     correlating cast-timing against a nameplate UNIT_SPELLCAST_INTERRUPTED
--     signal within a ~55ms window (or, failing that, guessing by proximity/
--     targeting). That's gone: UNIT_SPELLCAST_INTERRUPTED's `interruptedBy`
--     names the interrupter directly, so attribution is exact instead of a
--     timing guess. The old SIGNAL CORRELATION section (signal tape, match
--     window, aura/cluster suppression, proximity fallback) is removed
--     entirely -- CONFIRM HIT below replaces it.
--   - No global export (the reference exposed `_G.InterruptTrackerReference`
--     for standalone testing). Cross-section forward references that the
--     reference solved with a global `ITR` table (`ITR.onKickDetected` /
--     `ITR.onKickRegistryChanged`) now go through a local `Hooks` table
--     instead -- same indirection, but private to this file.
--   - All event registration is gated behind Enabled (EnableRuntime/
--     DisableRuntime), matching every other Voidlol module -- the reference
--     registered its event frames unconditionally at file load.
--   - The reference implemented its own draggable/resizable "window" (title
--     bar, background, border, drag, resize handle, per-frame lock toggle)
--     that the bars sat inside. There's no separate window here at all --
--     the bar stack itself IS the tracker, auto-sized to fit however many
--     bars are currently shown. Position is dragged via EllesmereUI's shared
--     Unlock Mode (mirrors HealerMana/StatusBar); bar width is its own
--     Options setting instead of a drag-resize handle.
--   - Tracking/display treats any party1-4 occupant as trackable, same as
--     the reference -- including follower-dungeon NPCs, which do have a
--     class and can be usefully tracked. Only the PARTY-channel SYNC
--     requires a *real* player in the group (IsRealParty(), UnitIsPlayer
--     check): follower dungeons have no actual party chat channel behind
--     them, so without this check, syncing tried to chat on a channel that
--     doesn't exist there, spamming "You aren't in a party" every roster
--     update.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EVL = ns.EVL

-------------------------------------------------------------------------------
--  Technical constants -- NOT user settings (see file header).
-------------------------------------------------------------------------------
local REFRESH_INTERVAL       = 0.05  -- seconds between bar redraws (20/s)
local MISS_CONFIRM_DELAY     = 0.5   -- seconds to wait for an interruptedBy hit confirmation before declaring a detected cast attempt a miss
local INSPECT_RETRY_DELAYS   = { 1, 2, 4, 8, 15, 25 } -- seconds; spec-learning retry schedule
local SYNC_PREFIX            = "ITKICK1" -- C_ChatInfo addon-message prefix (<=16 chars)
local SYNC_MESSAGE_PREFIX    = "IT1"     -- tag prepended to our payloads
local SYNC_BROADCAST_DELAY   = 1.0   -- seconds to debounce after a roster change before broadcasting
local SYNC_QUERY_MIN_INTERVAL = 3.0  -- min seconds between "send me your state" requests
local BLIZZARD_BAR_TEXTURE    = "Interface\\TargetingFrame\\UI-StatusBar"

-------------------------------------------------------------------------------
--  DB accessor
-------------------------------------------------------------------------------
local function DB()
    local d = EVL.DB and EVL.DB()
    return d and d.interruptTracker
end

-------------------------------------------------------------------------------
--  SPELL DATABASE
--  classKicks    = fallback interrupt when a party member's spec isn't known yet
--  specOverrides = spec-specific interrupt spell/CD, takes priority over classKicks
--  noKickSpecs   = specs with no reliable interrupt (most healer specs)
--  aliases       = spellIDs that may fire in place of the canonical interrupt ID
-------------------------------------------------------------------------------
local classKicks = {
    DEATHKNIGHT = { id = 47528,  cd = 15, name = "Mind Freeze"       },
    DEMONHUNTER = { id = 183752, cd = 15, name = "Disrupt"           },
    DRUID       = { id = 106839, cd = 15, name = "Skull Bash"        },
    EVOKER      = { id = 351338, cd = 40, name = "Quell"             },
    HUNTER      = { id = 147362, cd = 24, name = "Counter Shot"      },
    MAGE        = { id = 2139,   cd = 24, name = "Counterspell"      },
    MONK        = { id = 116705, cd = 15, name = "Spear Hand Strike" },
    PALADIN     = { id = 96231,  cd = 15, name = "Rebuke"            },
    PRIEST      = { id = 15487,  cd = 45, name = "Silence"           },
    ROGUE       = { id = 1766,   cd = 15, name = "Kick"              },
    SHAMAN      = { id = 57994,  cd = 12, name = "Wind Shear"        },
    WARLOCK     = { id = 19647,  cd = 24, name = "Spell Lock"        },
    WARRIOR     = { id = 6552,   cd = 15, name = "Pummel"            },
}

local specOverrides = {
    [102] = { id = 78675,  cd = 60, name = "Solar Beam"  }, -- Balance Druid
    [103] = { id = 106839, cd = 15, name = "Skull Bash"  },
    [104] = { id = 106839, cd = 15, name = "Skull Bash"  },
    [105] = {}, -- Restoration Druid: no reliable kick
    [65]  = {}, -- Holy Paladin
    [264] = { id = 57994,  cd = 30, name = "Wind Shear"  }, -- Restoration Shaman (30s instead of 12s)
    [270] = {}, -- Mistweaver Monk
    [257] = {}, -- Holy Priest
    [1468]= {}, -- Preservation Evoker
    [266] = { id = 119914, cd = 24, name = "Axe Toss", isPet = true }, -- Demonology Warlock (pet ability)
}

local noKickSpecs = { [105] = true, [65] = true, [264] = true, [270] = true, [257] = true, [1468] = true }

local aliases = {
    [132409] = 19647, [119898] = 19647, [119910] = 19647,
    [171138] = 19647, [171140] = 19647, [212619] = 19647,
    [119914] = 89766,  -- Axe Toss -> Spell Lock (Demonology)
    [455395] = 63560,
    [78675]  = 106839, -- Solar Beam can fire under this ID too
}

-- Talents that change a class's interrupt cooldown (own player only).
-- mode: "flat" = subtract `amount` seconds | "multiplier" = CD * amount | "set" = CD = amount
local specialInterruptTalentDefinitions = {
    {
        flag = "quick_witted", classTag = "MAGE", specIDs = { 62, 63, 64 },
        talentName = "Quick Witted", talentSpellID = 382297,
        interruptSpellID = 2139, mode = "flat", amount = 5,
    },
    {
        flag = "honed_reflexes", classTag = "WARRIOR", specIDs = { 71, 72, 73 },
        talentName = "Honed Reflexes", talentSpellID = 391271,
        interruptSpellID = 6552, mode = "multiplier", amount = 0.9,
    },
    {
        flag = "interwoven_threads", classTag = "EVOKER", specIDs = { 1473 },
        talentName = "Interwoven Threads", talentSpellID = 412713,
        interruptSpellID = 351338, mode = "multiplier", amount = 0.9,
    },
    {
        flag = "fel_ravager", classTag = "WARLOCK", specIDs = { 265, 266, 267 },
        talentName = "Grimoire: Fel Ravager", talentSpellID = 1276467,
        interruptSpellID = 19647, mode = "set", amount = 24,
    },
}

-- Built lookup tables from the raw database above.
local ALL_INTERRUPTS         = {} -- [spellID] = { id, cd, name, class? }
local ALL_INTERRUPTS_STR     = {} -- [tostring(spellID)] = same
local SPELL_ALIASES          = {} -- [aliasID] = canonicalID
local SPELL_ALIASES_STR      = {} -- [tostring(aliasID)] = canonicalID
local CLASS_INTERRUPTS       = {} -- [classTag] = data
local SPEC_INTERRUPT_OVERRIDES = {} -- [specID] = data
local SPEC_NO_INTERRUPT      = {} -- [specID] = true

for cls, data in pairs(classKicks) do
    data.class = cls
    CLASS_INTERRUPTS[cls] = data
    ALL_INTERRUPTS[data.id] = data
    ALL_INTERRUPTS_STR[tostring(data.id)] = data
end
for specID, ov in pairs(specOverrides) do
    if ov.id then
        SPEC_INTERRUPT_OVERRIDES[specID] = ov
        ALL_INTERRUPTS[ov.id] = ov
        ALL_INTERRUPTS_STR[tostring(ov.id)] = ov
    end
end
for specID in pairs(noKickSpecs) do
    SPEC_NO_INTERRUPT[specID] = true
end
for alias, target in pairs(aliases) do
    SPELL_ALIASES[alias] = target
    SPELL_ALIASES_STR[tostring(alias)] = target
end

-------------------------------------------------------------------------------
--  TAINT-SAFE NUMBER/STRING RESOLUTION (WoW 12.x)
--  Party members' UNIT_SPELLCAST_SUCCEEDED spellID (and some CHAT_MSG_ADDON
--  fields) are "secret" values in Midnight -- indexing a table with them
--  directly throws. These helpers launder a secret value back into plain Lua
--  via APIs that execute outside the taint boundary (string.format, a hidden
--  Slider's OnValueChanged, or byte-at-a-time string.byte reads).
-------------------------------------------------------------------------------
local ResolveNumber
do
    local slider = CreateFrame("Slider", nil, UIParent)
    slider:SetMinMaxValues(0, 9999999)
    slider:SetSize(1, 1)
    slider:Hide()
    local sliderResult = nil
    slider:SetScript("OnValueChanged", function(_, v) sliderResult = v end)

    ResolveNumber = function(raw)
        if raw == nil then return nil end
        if type(raw) == "number" then
            local ok = pcall(function() local _ = ({ [raw] = 1 })[raw] end)
            if ok then return raw end
        end
        local okF, s = pcall(string.format, "%.0f", raw)
        if okF and s then
            local n = tonumber(s)
            if n then
                local ok2 = pcall(function() local _ = ({ [n] = 1 })[n] end)
                if ok2 then return n end
            end
        end
        pcall(slider.SetValue, slider, 0)
        sliderResult = nil
        local ok3 = pcall(slider.SetValue, slider, raw)
        if ok3 and sliderResult and sliderResult ~= 0 then
            return math.floor(sliderResult + 0.5)
        end
        return nil
    end
end

-- Rebuilds a plain Lua string out of a possibly-secret one, one byte at a
-- time. No-op (fast path) when the value isn't secret at all.
local function ScrubSecretString(raw, maxLen)
    if raw == nil then return nil end
    if type(raw) == "string" and not (issecretvalue and issecretvalue(raw)) then
        return raw
    end
    local parts = {}
    for i = 1, (maxLen or 255) do
        local okB, b = pcall(string.byte, raw, i)
        if not okB or not b then break end
        local okC, ch = pcall(string.char, b)
        if not okC or not ch then break end
        parts[#parts + 1] = ch
    end
    if #parts == 0 then return nil end
    return table.concat(parts)
end

local function NormalizeName(name)
    if name == nil then return "Unknown" end
    if issecretvalue and issecretvalue(name) then return "Unknown" end
    local ok, shortName = pcall(Ambiguate, name, "short")
    if not ok or not shortName then return "Unknown" end
    -- Ambiguate doesn't strip secrecy -- a secret input can come back out
    -- still secret with no pcall error, so it must be checked again here too
    -- (not just on the raw input above) before this is ever used as a table
    -- key (kickRegistry[name]), which errors: "attempted to index a table
    -- that cannot be indexed with secret keys".
    if issecretvalue and issecretvalue(shortName) then return "Unknown" end
    return shortName
end

local function SafeUnitName(unit)
    local ok, name = pcall(UnitName, unit)
    return (ok and name) and NormalizeName(name) or nil
end

-- Follower dungeons (Delves-with-NPCs, "Follower Dungeon" difficulty, etc.)
-- put you in a group for UI/loot purposes -- IsInGroup()/GetNumGroupMembers()
-- see it as a real group -- but there's no actual party chat channel behind
-- it, so C_ChatInfo.SendAddonMessage(..., "PARTY") fails and prints
-- "You aren't in a party" every time it's attempted. Follower NPCs occupying
-- party1-4 are not players (UnitIsPlayer is false for them), so requiring at
-- least one real player in the group is a reliable way to tell a real party
-- apart from a follower-only one.
local function IsRealParty()
    if IsInRaid() then return true end
    if not (IsInGroup() or IsInGroup(LE_PARTY_CATEGORY_INSTANCE)) then return false end
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) and UnitIsPlayer(u) then return true end
    end
    return false
end

-------------------------------------------------------------------------------
--  SPEC RESOLUTION
--  Tooltip parsing avoids the taint that GetInspectSpecialization carries
--  before an inspect completes; it's used as the primary path, with
--  GetInspectSpecialization as a fallback once an inspect has gone through.
-------------------------------------------------------------------------------
local specCache = {} -- [guid] = specID
local specNameMap     -- [ "Specialization Name Class Name" ] = specID, built lazily

local function GetSpecForUnit(unit)
    if not unit or not UnitExists(unit) then return nil end
    if unit == "player" then
        local si = GetSpecialization and GetSpecialization()
        return si and select(1, GetSpecializationInfo(si)) or nil
    end

    local guid = UnitGUID(unit)
    if guid and specCache[guid] then return specCache[guid] end

    if C_TooltipInfo and C_TooltipInfo.GetUnit then
        local ok, td = pcall(C_TooltipInfo.GetUnit, unit)
        if ok and td then
            if not specNameMap then
                specNameMap = {}
                if GetNumClasses and GetClassInfo and GetNumSpecializationsForClassID and GetSpecializationInfoForClassID then
                    for ci = 1, GetNumClasses() do
                        local cn, _, cid = GetClassInfo(ci)
                        if cn and cid then
                            for si2 = 1, GetNumSpecializationsForClassID(cid) do
                                local sid2, sn2 = GetSpecializationInfoForClassID(cid, si2)
                                if sid2 and sn2 then specNameMap[sn2 .. " " .. cn] = sid2 end
                            end
                        end
                    end
                end
            end
            for _, line in ipairs(td.lines or {}) do
                if line and line.leftText and not issecretvalue(line.leftText) then
                    local sid = specNameMap[line.leftText]
                    if sid then
                        if guid then specCache[guid] = sid end
                        return sid
                    end
                end
            end
        end
    end

    if GetInspectSpecialization then
        local sid = GetInspectSpecialization(unit)
        if sid and sid > 0 then
            if guid then specCache[guid] = sid end
            return sid
        end
    end
    return nil
end

-------------------------------------------------------------------------------
--  OWN-PLAYER TALENT-BASED COOLDOWN ADJUSTMENTS
--  Some talents change how long your own interrupt's cooldown is. These only
--  apply to the local player (can't be verified for party members without
--  reading their exact talent build).
-------------------------------------------------------------------------------
local function IsSpecialTalentRelevant(def, classTag, specID)
    if def.classTag and def.classTag ~= classTag then return false end
    if def.specIDs and #def.specIDs > 0 then
        for _, v in ipairs(def.specIDs) do
            if v == specID then return true end
        end
        return false
    end
    return true
end

local function HasTalentSpellID(spellID)
    if not spellID then return false end
    if IsPlayerSpell and IsPlayerSpell(spellID) then return true end
    return false
end

local function PlayerHasSpecialInterruptTalent(def, classTag, specID)
    local cfg = DB()
    if not cfg or not cfg.enableTalentAdjustments then return false end
    if not IsSpecialTalentRelevant(def, classTag, specID) then return false end
    if def.talentSpellID and HasTalentSpellID(def.talentSpellID) then return true end
    return false
end

-- Given the base (spellID, cd) picked for the player's class/spec, apply any
-- talent-driven adjustment that changes the effective cooldown.
local function ApplyOwnTalentCdAdjustment(spellID, cd, classTag, specID)
    local cfg = DB()
    if not cfg or not cfg.enableTalentAdjustments then return cd end
    for _, def in ipairs(specialInterruptTalentDefinitions) do
        if def.interruptSpellID == spellID and PlayerHasSpecialInterruptTalent(def, classTag, specID) then
            if def.mode == "flat" then
                cd = math.max(1, cd - (def.amount or 0))
            elseif def.mode == "multiplier" then
                cd = math.max(1, cd * (def.amount or 1))
            elseif def.mode == "set" then
                cd = def.amount or cd
            end
        end
    end
    return cd
end

-------------------------------------------------------------------------------
--  Internal hook table -- breaks the circular dependency between the kick
--  registry (below) and the bar UI / sync sections (further down) without a
--  global. Assigned once both sides exist (near the end of this file);
--  guarded with `if Hooks.xxx then` everywhere it's called from, so it's a
--  no-op if something ever fires mid-load (never happens in practice --
--  events can't fire until the whole file has finished executing).
-------------------------------------------------------------------------------
local Hooks = {}

-------------------------------------------------------------------------------
--  KICK REGISTRY
--  [name] = { spellID, baseCd, cdEnd, class, lastKickAt, lastKickResult, missTimer }
-------------------------------------------------------------------------------
local kickRegistry    = {}
local kickNoInterrupt = {} -- [name] = true (e.g. a healer spec with no kick)

local function KickRegCreate(name)
    if not kickRegistry[name] then
        kickRegistry[name] = { spellID = 0, baseCd = 15, cdEnd = 0, class = nil, lastKickResult = nil, missTimer = nil }
    end
    return kickRegistry[name]
end

-- CONFIRM HIT: entry.lastKickResult tracks whether the most recently
-- detected cast attempt for this member actually landed --
-- nil/"pending"/"hit"/"miss". SetKickPending is called the moment a cast
-- attempt is detected (own UNIT_SPELLCAST_SUCCEEDED, or a party member's
-- inferred cast); if no ConfirmKickHit arrives for them within
-- MISS_CONFIRM_DELAY, the pending timer declares it a miss. Real interrupt
-- abilities land (or don't) essentially instantly, so this window is
-- generous, not tight like the old correlation match window.
local function CancelMissTimer(entry)
    if entry.missTimer then
        entry.missTimer:Cancel()
        entry.missTimer = nil
    end
end

local function SetKickPending(entry)
    CancelMissTimer(entry)
    entry.lastKickResult = "pending"
    entry.missTimer = C_Timer.NewTimer(MISS_CONFIRM_DELAY, function()
        entry.missTimer = nil
        if entry.lastKickResult == "pending" then
            entry.lastKickResult = "miss"
            if Hooks.onKickRegistryChanged then Hooks.onKickRegistryChanged() end
        end
    end)
end

local function ConfirmKickHit(entry)
    CancelMissTimer(entry)
    entry.lastKickResult = "hit"
end

-- Registers party members by class the moment they're visible, so a
-- "no addon data yet" placeholder can be shown immediately, refined with
-- their real spec (and possibly a different interrupt spell/CD) once an
-- inspect or tooltip resolves their specialization.
local function AutoRegisterParty()
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then
            local name = SafeUnitName(u)
            local _, cls = UnitClass(u)
            if name and cls and CLASS_INTERRUPTS[cls] and not kickRegistry[name] and not kickNoInterrupt[name] then
                local role = UnitGroupRolesAssigned(u)
                if role ~= "HEALER" then
                    local kick = CLASS_INTERRUPTS[cls]
                    local entry = KickRegCreate(name)
                    entry.class = cls
                    entry.spellID = kick.id
                    entry.baseCd = kick.cd

                    local guid = UnitGUID(u)
                    local specID = specCache[guid] or (GetInspectSpecialization and GetInspectSpecialization(u))
                    if specID and specID > 0 then
                        if SPEC_NO_INTERRUPT[specID] then
                            kickRegistry[name] = nil
                            kickNoInterrupt[name] = true
                        elseif SPEC_INTERRUPT_OVERRIDES[specID] and SPEC_INTERRUPT_OVERRIDES[specID].id then
                            local ov = SPEC_INTERRUPT_OVERRIDES[specID]
                            entry.spellID = ov.id
                            entry.baseCd = ov.cd
                        end
                    else
                        for _, delay in ipairs(INSPECT_RETRY_DELAYS) do
                            C_Timer.After(delay, function()
                                if not UnitExists(u) then return end
                                local sid = GetInspectSpecialization and GetInspectSpecialization(u)
                                if not (sid and sid > 0) then return end
                                local e2 = kickRegistry[name]
                                if not e2 then return end
                                if SPEC_NO_INTERRUPT[sid] then
                                    kickRegistry[name] = nil
                                    kickNoInterrupt[name] = true
                                elseif SPEC_INTERRUPT_OVERRIDES[sid] and SPEC_INTERRUPT_OVERRIDES[sid].id then
                                    local ov = SPEC_INTERRUPT_OVERRIDES[sid]
                                    e2.spellID = ov.id
                                    e2.baseCd = ov.cd
                                end
                                if guid then specCache[guid] = sid end
                                if Hooks.onKickRegistryChanged then Hooks.onKickRegistryChanged() end
                            end)
                        end
                    end
                end
            end
        end
    end
end

-- Own player: spellID is read directly (not tainted for the local unit).
local function HandleOwnKick(spellID)
    local now = GetTime()
    local myName = SafeUnitName("player")
    if not myName then return end

    local resolvedID = SPELL_ALIASES[spellID] or spellID
    local spellData = ALL_INTERRUPTS[resolvedID]
    if not spellData then return end

    local _, cls = UnitClass("player")
    local specID = GetSpecForUnit("player")

    -- Resolve the RAW (pre-talent-adjustment) base cooldown the same
    -- spec-aware way AutoRegisterSelf does -- NOT from the shared
    -- ALL_INTERRUPTS lookup, which can only hold one cd per spellID and gets
    -- overwritten by specOverrides even for specs that don't have that
    -- override (e.g. Wind Shear is 57994 for every Shaman spec, but
    -- ALL_INTERRUPTS[57994].cd ends up permanently at Resto's 30s, wrong for
    -- everyone else). Must stay RAW here (not entry.baseCd) since that may
    -- already carry a previous talent adjustment -- reusing it would
    -- compound the reduction further on every subsequent cast.
    local cd = spellData.cd
    if specID and SPEC_INTERRUPT_OVERRIDES[specID] and SPEC_INTERRUPT_OVERRIDES[specID].id == resolvedID then
        cd = SPEC_INTERRUPT_OVERRIDES[specID].cd
    elseif CLASS_INTERRUPTS[cls] and CLASS_INTERRUPTS[cls].id == resolvedID then
        cd = CLASS_INTERRUPTS[cls].cd
    end

    -- DK: manual "successful interrupt shortens my next Mind Freeze" talent
    local cfg = DB()
    if resolvedID == 47528 and cfg and cfg.dkMindFreezeCDRTalent then
        cd = math.max(1, cd - (cfg.dkMindFreezeCDRAmount or 3))
    end
    cd = ApplyOwnTalentCdAdjustment(resolvedID, cd, cls, specID)

    local entry = kickRegistry[myName] or KickRegCreate(myName)
    entry.class = cls
    entry.spellID = resolvedID
    entry.baseCd = cd
    entry.cdEnd = now + cd
    entry.lastKickAt = now
    SetKickPending(entry)

    if Hooks.onKickDetected then
        Hooks.onKickDetected(myName, resolvedID, cd, entry.cdEnd)
    end
end

-------------------------------------------------------------------------------
--  CONFIRM HIT -- resolves who actually landed a detected interrupt, from
--  UNIT_SPELLCAST_INTERRUPTED / _CHANNEL_STOP's `interruptedBy` GUID. See
--  the file header for why this is reliable despite the GUID being secret.
-------------------------------------------------------------------------------
local function FindPartyUnitByName(name)
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) and SafeUnitName(u) == name then return u end
    end
    return nil
end

-- REACTIVE MODEL for party members (own kick tracking is unaffected --
-- HandleOwnKick above still runs off UNIT_SPELLCAST_SUCCEEDED("player"),
-- which was never the unreliable part). We no longer try to detect a party
-- member's cast ATTEMPT at all (that required laundering a tainted spellID
-- off their UNIT_SPELLCAST_SUCCEEDED and guessing whether it was their kick
-- vs any other ability -- see the removed ResolveInterruptSpell/
-- HandlePartyCast/taint-slider machinery). Instead, a teammate's bar is
-- created and its cooldown STARTED right here, the instant their interrupt
-- is confirmed landed -- there's no "pending"/"miss" state for teammates
-- anymore, since we only ever observe a landed hit, never an attempt. This
-- mirrors how EXBoss's interrupt tracker works (reactive-only for teammates)
-- and trades away the "cooldown counting down before it's confirmed" nicety
-- for a much smaller, sturdier surface: no tainted-spellID resolution, no
-- extraKicks bookkeeping, one clear responsibility per event.
local function ConfirmInterruptHit(interruptedBy)
    if interruptedBy == nil then return end

    -- UnitTokenFromGUID does NOT return nil for a party member's landed
    -- interrupt -- it returns a STILL-SECRET string token (truthy, non-nil,
    -- but unusable). Comparing a secret value with == throws ("attempt to
    -- compare ... a secret string value"), so issecretvalue MUST be checked
    -- before the equality check ever runs -- only a non-secret token can
    -- safely be compared to "player" at all.
    local okToken, token = pcall(UnitTokenFromGUID, interruptedBy)
    if okToken and token and not (issecretvalue and issecretvalue(token)) and token == "player" then
        local myName = SafeUnitName("player")
        local myEntry = myName and kickRegistry[myName]
        if myEntry then
            ConfirmKickHit(myEntry)
            if Hooks.onKickRegistryChanged then Hooks.onKickRegistryChanged() end
        end
        return
    end

    -- Not us -- UnitNameFromGUID is documented to resolve a display name
    -- even on a secret GUID, but in practice (observed live, e.g. Mythic+)
    -- it can still come back secret for a party member's GUID. When that
    -- happens we simply can't attribute this hit to anyone -- same
    -- limitation EXBoss's own interrupt tracker has (its AddInterruptRecord
    -- returns false/"name_unresolved" in the same situation) -- so we skip
    -- it rather than guess.
    local okName, rawName = pcall(UnitNameFromGUID, interruptedBy)
    if not okName or not rawName or (issecretvalue and issecretvalue(rawName)) then return end
    local name = NormalizeName(rawName)

    local entry = kickRegistry[name]
    if not entry or not entry.spellID or entry.spellID == 0 then
        -- Not registered yet (or registered as "no addon data") -- this hit
        -- confirmation is the strongest signal we'll get for them, so
        -- register now from their class if we can find their unit.
        local u = FindPartyUnitByName(name)
        local _, cls = u and UnitClass(u)
        local kick = cls and CLASS_INTERRUPTS[cls]
        if not kick then return end
        entry = KickRegCreate(name)
        entry.class = cls
        entry.spellID = kick.id
        entry.baseCd = kick.cd
    end

    -- Start (or restart) their cooldown from right now -- the moment their
    -- interrupt is confirmed landed is the only moment we ever observe them.
    local now = GetTime()
    entry.cdEnd = now + entry.baseCd
    entry.lastKickAt = now
    ConfirmKickHit(entry)
    if Hooks.onKickRegistryChanged then Hooks.onKickRegistryChanged() end
end

-------------------------------------------------------------------------------
--  Forward declarations: assigned in the SYNC section further down, but the
--  roster-update handler wired up in EVENT WIRING needs to call both on
--  every roster change.
-------------------------------------------------------------------------------
local AutoRegisterSelf
local SyncOnRosterChange

-------------------------------------------------------------------------------
--  EVENT WIRING -- feeds the detection engine above. Frames are created here
--  but events are only REGISTERED from EnableRuntime (below), matching every
--  other Voidlol module's enabled-gated runtime pattern.
-------------------------------------------------------------------------------
local playerFrame = CreateFrame("Frame", nil, UIParent); playerFrame:Hide()
playerFrame:SetScript("OnEvent", function(_, _, unit, _, spellID)
    if unit == "pet" then
        local usedID
        local ok, hit = pcall(function() return ALL_INTERRUPTS[spellID] end)
        if ok and hit then usedID = spellID end
        if not usedID then
            local ok2, s = pcall(tostring, spellID)
            if ok2 and s then
                if ALL_INTERRUPTS_STR[s] then usedID = tonumber(s) end
                if not usedID then
                    local t = SPELL_ALIASES_STR[s]
                    if t and ALL_INTERRUPTS[t] then usedID = t end
                end
            end
        end
        if not usedID then usedID = ResolveNumber(spellID) end
        if usedID and ALL_INTERRUPTS[usedID] then
            HandleOwnKick(usedID)
        end
    else
        local resolvedID = SPELL_ALIASES[spellID] or spellID
        if ALL_INTERRUPTS[resolvedID] then
            HandleOwnKick(resolvedID)
        end
    end
end)

-- Nameplates: UNIT_SPELLCAST_INTERRUPTED / _CHANNEL_STOP's interruptedBy
-- names who landed it directly -- see CONFIRM HIT.
local npFrame = CreateFrame("Frame", nil, UIParent); npFrame:Hide()
npFrame:SetScript("OnEvent", function(_, event, unit, castGUID, spellID, interruptedBy)
    if not (unit and unit:find("^nameplate")) then return end
    ConfirmInterruptHit(interruptedBy)
end)

local rosterFrame = CreateFrame("Frame", nil, UIParent); rosterFrame:Hide()
rosterFrame:SetScript("OnEvent", function()
    AutoRegisterParty()
    if AutoRegisterSelf then AutoRegisterSelf() end
    if SyncOnRosterChange then SyncOnRosterChange() end
end)

-------------------------------------------------------------------------------
--  BAR UI -- one status bar per tracked party member
-------------------------------------------------------------------------------
-- No separate "window" frame -- `anchor` IS the bar stack: an invisible
-- positioning root sized to fit its bars, dragged via Unlock Mode. Bars
-- parent directly to it.
local anchor
local bars = {}
local unlockStubActive = false

local function GetFontPath(fontKey)
    if fontKey == "__global" or not fontKey then
        return (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath()) or "Fonts\\FRIZQT__.TTF"
    end
    return (EllesmereUI.ResolveFontName and EllesmereUI.ResolveFontName(fontKey)) or "Fonts\\FRIZQT__.TTF"
end

local function GetBarTexturePath()
    local cfg = DB()
    local key = cfg and cfg.barTexture
    if not key or key == "Blizzard" then return BLIZZARD_BAR_TEXTURE end
    local smName = key:match("^sm:(.+)")
    if smName then
        local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
        local fetched = LSM and LSM:Fetch("statusbar", smName, true)
        if fetched then return fetched end
    end
    return BLIZZARD_BAR_TEXTURE
end

local function GetClassColor(classTag)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classTag]
    if c then return c.r, c.g, c.b end
    return 0.75, 0.75, 0.75
end

local function GetClassCoords(classTag)
    if CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classTag] then
        local t = CLASS_ICON_TCOORDS[classTag]
        return t[1], t[2], t[3], t[4]
    end
    return 0, 1, 0, 1
end

local function SafeGetSpellTexture(spellID)
    if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(spellID) end
    return nil
end

local function EnsureAnchor()
    if anchor then return anchor end

    anchor = CreateFrame("Frame", "EllesmereUIVoidlol_InterruptTracker", UIParent)
    anchor:SetClampedToScreen(true)
    anchor:Hide()

    return anchor
end

local function CreateBar(parent)
    local bar = CreateFrame("StatusBar", nil, parent or anchor)
    bar:SetMinMaxValues(0, 1)
    bar:SetStatusBarTexture(GetBarTexturePath())

    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()

    local PP = EllesmereUI and EllesmereUI.PP
    if PP and PP.CreateBorder then PP.CreateBorder(bar, 0, 0, 0, 1, 1, "BORDER", 7) end

    bar.overlay = CreateFrame("Frame", nil, bar)
    bar.overlay:SetAllPoints()
    bar.overlay:SetFrameLevel(bar:GetFrameLevel() + 10)

    bar.icon = CreateFrame("Frame", nil, bar.overlay)
    bar.icon.bg = bar.icon:CreateTexture(nil, "BACKGROUND")
    bar.icon.bg:SetAllPoints()
    bar.icon.bg:SetColorTexture(0, 0, 0, 0.6)
    bar.icon.tex = bar.icon:CreateTexture(nil, "ARTWORK")
    bar.icon.tex:SetPoint("TOPLEFT", 1, -1)
    bar.icon.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    bar.icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if PP and PP.CreateBorder then PP.CreateBorder(bar.icon, 0, 0, 0, 1, 1, "BORDER", 7) end

    bar.nameText = bar.overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bar.nameText:SetJustifyH("LEFT")
    bar.timeText = bar.overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bar.timeText:SetJustifyH("RIGHT")

    -- Hit/miss result badge for the most recent cast attempt while on
    -- cooldown -- centered on the bar itself (see RefreshBars).
    bar.resultIcon = bar.overlay:CreateTexture(nil, "OVERLAY", nil, 1)
    bar.resultIcon:SetPoint("CENTER", bar, "CENTER", 0, 0)
    bar.resultIcon:Hide()

    bar:Hide()
    return bar
end

local function EnsureBars(count)
    for i = #bars + 1, count do
        bars[i] = CreateBar()
    end
end

-- Anchored by TOPLEFT (not CENTER): with a CENTER anchor, the stack
-- resizing (bar count or bar-width changes) would expand it equally in
-- both directions around a fixed center point. TOPLEFT keeps that corner
-- pinned instead.
local function ApplyPosition()
    local cfg = DB()
    if not cfg or not anchor then return end

    local fes = anchor:GetEffectiveScale() or 1
    local ues = UIParent:GetEffectiveScale() or 1
    local ratio = fes / ues
    local w = (anchor:GetWidth() or 0) * ratio
    local h = (anchor:GetHeight() or 0) * ratio

    anchor:ClearAllPoints()
    if cfg.pos then
        anchor:SetPoint("TOPLEFT", UIParent, "CENTER", cfg.pos.left, cfg.pos.top)
    else
        anchor:SetPoint("TOPLEFT", UIParent, "CENTER", -w / 2, h / 2)
    end
end

-- Applies every settings-driven visual to ONE bar (size/font/colors/border/
-- icon position) -- everything except the bar's own position relative to
-- its neighbors, which differs between the live stack (ApplyLayout) and the
-- options-page preview (EVL.InterruptTracker_RefreshPreviewGroup), both of
-- which call this so a settings change looks identical in both places.
local function StyleBar(bar, cfg, iconSize, barWidth, fontPath, thickness, PP)
    bar:SetSize(barWidth, cfg.barHeight or 24)
    bar:SetStatusBarTexture(GetBarTexturePath())
    if bar.SetReverseFill then bar:SetReverseFill(cfg.reverseFill == true) end
    -- Alpha is baked in at 1 here -- RenderBarEntry scales the actual
    -- displayed opacity per-frame via bar.bg:SetAlpha(), since the "ready"
    -- state additionally fades the background along with the Ready Color's
    -- own alpha.
    bar.bg:SetColorTexture(cfg.barBgColorR or 0.08, cfg.barBgColorG or 0.08, cfg.barBgColorB or 0.08, 1)
    bar.resultIcon:SetSize(math.max(8, (cfg.barHeight or 24) - 8), math.max(8, (cfg.barHeight or 24) - 8))

    if PP and PP.ShowBorder and PP.HideBorder then
        if thickness <= 0 then
            PP.HideBorder(bar)
            PP.HideBorder(bar.icon)
        else
            PP.ShowBorder(bar)
            PP.ShowBorder(bar.icon)
            if PP.SetBorderSize then
                PP.SetBorderSize(bar, thickness)
                PP.SetBorderSize(bar.icon, thickness)
            end
        end
    end

    bar.icon:ClearAllPoints()
    bar.icon:SetSize(iconSize, iconSize)
    if cfg.iconPosition == "right" then
        bar.icon:SetPoint("LEFT", bar, "RIGHT", cfg.iconGap or 4, 0)
    else
        bar.icon:SetPoint("RIGHT", bar, "LEFT", -(cfg.iconGap or 4), 0)
    end

    bar.nameText:SetFont(fontPath, cfg.fontSize or 12, "")
    bar.timeText:SetFont(fontPath, cfg.fontSize or 12, "")
    bar.nameText:SetTextColor(cfg.textColorR or 1, cfg.textColorG or 1, cfg.textColorB or 1, 1)
    bar.timeText:SetTextColor(cfg.textColorR or 1, cfg.textColorG or 1, cfg.textColorB or 1, 1)

    bar.timeText:ClearAllPoints()
    bar.timeText:SetPoint("RIGHT", bar, "RIGHT", -6, 0)
    bar.nameText:ClearAllPoints()
    bar.nameText:SetPoint("LEFT", bar, "LEFT", 6, 0)
    bar.nameText:SetPoint("RIGHT", bar.timeText, "LEFT", -6, 0)
end

-- Styles every bar in the pool and positions it in the live stack --
-- independent of how many are actually shown right now, that's
-- UpdateAnchorSize's job (called from RefreshBars every redraw, since the
-- shown count changes live).
local function ApplyLayout()
    local cfg = DB()
    if not cfg or not anchor then return end

    local iconSize = cfg.barHeight or 24 -- icon is a square exactly matching the bar's own height
    local barWidth = cfg.barWidth or 200
    local fontPath = GetFontPath(cfg.fontFace)
    local PP = EllesmereUI and EllesmereUI.PP
    local thickness = cfg.borderThickness
    if thickness == nil then thickness = 1 end

    for i = 1, #bars do
        local bar = bars[i]
        bar:ClearAllPoints()
        StyleBar(bar, cfg, iconSize, barWidth, fontPath, thickness, PP)

        if i == 1 then
            if cfg.iconPosition == "right" then
                bar:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
            else
                bar:SetPoint("TOPLEFT", anchor, "TOPLEFT", iconSize + (cfg.iconGap or 4), 0)
            end
        else
            bar:SetPoint("TOPLEFT", bars[i - 1], "BOTTOMLEFT", 0, -(cfg.barSpacing or 6))
        end
    end
end

-- Resizes `anchor` to exactly fit `shownCount` bars (0 collapses it to one
-- row's height, so Unlock Mode always has a non-zero stub to grab even with
-- nothing tracked yet).
local function UpdateAnchorSize(shownCount)
    local cfg = DB()
    if not cfg or not anchor then return end

    local iconSize = cfg.barHeight or 24 -- icon is a square exactly matching the bar's own height
    local totalWidth = (cfg.barWidth or 200) + iconSize + (cfg.iconGap or 4)

    local n = math.max(shownCount or 0, 0)
    local barHeight = cfg.barHeight or 24
    local totalHeight
    if n <= 0 then
        totalHeight = barHeight
    else
        totalHeight = n * barHeight + math.max(0, n - 1) * (cfg.barSpacing or 6)
    end

    anchor:SetSize(math.max(1, totalWidth), math.max(1, totalHeight))
end

local function ShouldBeVisible()
    if unlockStubActive then return true end
    if IsInRaid() or (GetNumGroupMembers() or 0) > (DB() and DB().maxGroupSizeToShow or 5) then return false end
    -- Deliberately NOT gated on IsRealParty(): a follower-dungeon "group" has
    -- no working party chat (see IsRealParty's comment) so SYNC is disabled
    -- for it, but your own bar (and any real players' bars, if some are
    -- mixed in) should still track and display normally.
    if not IsInGroup() and not IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return false end

    local cfg = DB()
    local inInstance, instanceType = IsInInstance()
    if cfg and cfg.hideInDungeons and inInstance and instanceType == "party" then return false end
    if not (cfg and cfg.onlyInInstances) then return true end
    if not inInstance then return false end
    return instanceType == "party" or instanceType == "raid" or instanceType == "scenario"
end

-- Builds the sorted list of rows to display: ready entries first
-- (alphabetical), then on-cooldown entries (soonest-ready last / most-
-- recently-used first), then "no addon data yet" placeholders.
local function BuildDisplayList()
    local cfg = DB()
    local list = {}
    local now = GetTime()
    local myName = SafeUnitName("player")

    local function addFromRegistry(name, classTag)
        local reg = kickRegistry[name]
        if reg and reg.spellID and reg.spellID > 0 then
            list[#list + 1] = {
                name = name, classTag = classTag, spellID = reg.spellID,
                duration = reg.baseCd, endTime = reg.cdEnd or 0, noAddon = false,
                kickResult = reg.lastKickResult,
            }
            return true
        end
        return false
    end

    if myName then
        local _, myClass = UnitClass("player")
        addFromRegistry(myName, myClass)
    end

    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) then
            local name = SafeUnitName(u)
            local _, classTag = UnitClass(u)
            if name and classTag then
                local hasData = addFromRegistry(name, classTag)
                if not hasData and (not cfg or cfg.showNoAddonPlaceholders ~= false) and not kickNoInterrupt[name] then
                    list[#list + 1] = {
                        name = name, classTag = classTag, spellID = 0,
                        duration = 1, endTime = 0, noAddon = true,
                    }
                end
            end
        end
    end

    table.sort(list, function(a, b)
        if a.noAddon ~= b.noAddon then return not a.noAddon end
        local aReady = a.endTime <= now
        local bReady = b.endTime <= now
        if aReady ~= bReady then return aReady end
        if aReady and bReady then
            if a.name ~= b.name then return a.name < b.name end
            return a.spellID < b.spellID
        end
        if a.endTime ~= b.endTime then return a.endTime > b.endTime end
        return a.name < b.name
    end)

    return list
end

-- Renders ONE list entry onto ONE bar (value/icon/text/state colors/hit-miss
-- badge). Shared by RefreshBars (real data) and
-- EVL.InterruptTracker_RefreshPreviewGroup (fake data on the options page),
-- so a settings change looks identical in both.
local function RenderBarEntry(bar, entry, cfg, now)
    local remain = math.max(0, entry.endTime - now)
    local isReady = remain <= 0
    local value = (entry.noAddon or isReady) and 1 or (remain / math.max(entry.duration, 1))
    local cr, cg, cb = GetClassColor(entry.classTag)

    bar:SetValue(value)

    if bar._lastSpellID ~= entry.spellID or bar._lastNoAddon ~= entry.noAddon then
        if entry.noAddon then
            bar.icon.tex:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
            bar.icon.tex:SetTexCoord(GetClassCoords(entry.classTag))
        else
            bar.icon.tex:SetTexture(SafeGetSpellTexture(entry.spellID) or "Interface\\Icons\\INV_Misc_QuestionMark")
            bar.icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        bar._lastSpellID = entry.spellID
        bar._lastNoAddon = entry.noAddon
    end

    if bar._lastName ~= entry.name then
        bar.nameText:SetText(entry.name)
        bar._lastName = entry.name
    end

    local bgOpacity = cfg.barBgColorA or 0.95

    if entry.noAddon then
        bar:SetStatusBarColor(cfg.noAddonColorR or 0.2, cfg.noAddonColorG or 0.2, cfg.noAddonColorB or 0.2, (cfg.noAddonOpacity or 80) / 100)
        bar.bg:SetAlpha(bgOpacity)
        bar.timeText:SetText("No data")
        bar.timeText:SetTextColor(cfg.noAddonTextColorR or 0.6, cfg.noAddonTextColorG or 0.6, cfg.noAddonTextColorB or 0.6, 1)
        bar.nameText:SetTextColor(cfg.textColorR or 1, cfg.textColorG or 1, cfg.textColorB or 1, 1)
        bar.resultIcon:Hide()
    elseif isReady then
        -- The background sits behind the fill, so a translucent Ready
        -- Color alone would still show an opaque backdrop through it.
        -- Scaling the background by the same alpha lets Ready Color's
        -- alpha fade the WHOLE bar, not just the fill -- while the
        -- on-cooldown/no-data background opacity below is untouched,
        -- so the "remaining track" stays visible during a countdown.
        local readyAlpha = cfg.readyColorA or 1
        if cfg.keepReadyClassColor then
            bar:SetStatusBarColor(cr * 0.9, cg * 0.9, cb * 0.9, readyAlpha)
        else
            bar:SetStatusBarColor(cfg.readyColorR or 0, cfg.readyColorG or 0.78, cfg.readyColorB or 0.2, readyAlpha)
        end
        bar.bg:SetAlpha(bgOpacity * readyAlpha)
        bar.timeText:SetText("Ready")
        bar.timeText:SetTextColor(cfg.readyTextColorR or 0.2, cfg.readyTextColorG or 1, cfg.readyTextColorB or 0.2, 1)
        if cfg.nameColorReadyMode == "class" then
            bar.nameText:SetTextColor(cr, cg, cb, 1)
        else
            bar.nameText:SetTextColor(cfg.nameColorReadyR or 1, cfg.nameColorReadyG or 1, cfg.nameColorReadyB or 1, 1)
        end
        bar.resultIcon:Hide()
    else
        local mul = cfg.onCooldownColorMul or 0.7
        bar:SetStatusBarColor(cr * mul, cg * mul, cb * mul, cfg.onCooldownAlpha or 0.9)
        bar.bg:SetAlpha(bgOpacity)
        if cfg.nameColorCooldownMode == "class" then
            bar.nameText:SetTextColor(cr, cg, cb, 1)
        else
            bar.nameText:SetTextColor(cfg.nameColorCooldownR or 1, cfg.nameColorCooldownG or 1, cfg.nameColorCooldownB or 1, 1)
        end
        bar.timeText:SetText(remain >= 60
            and string.format("%dm%02d", math.floor(remain / 60), math.floor(remain % 60))
            or string.format("%.1f", remain))
        bar.timeText:SetTextColor(cfg.textColorR or 1, cfg.textColorG or 1, cfg.textColorB or 1, 1)

        -- Result of the cast that put this on cooldown: green check once
        -- UNIT_SPELLCAST_INTERRUPTED confirms it landed, red X if
        -- MISS_CONFIRM_DELAY passed with no confirmation. Nothing shown
        -- while still "pending" (just cast, not resolved yet).
        if entry.kickResult == "hit" then
            bar.resultIcon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
            bar.resultIcon:Show()
        elseif entry.kickResult == "miss" then
            bar.resultIcon:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
            bar.resultIcon:Show()
        else
            bar.resultIcon:Hide()
        end
    end
end

local function RefreshBars()
    local cfg = DB()
    if not cfg or not cfg.enabled or not anchor then return end

    if not ShouldBeVisible() then
        anchor:Hide()
        return
    end
    anchor:Show()

    local list = BuildDisplayList()

    -- There's no separate window frame anymore -- the bars ARE the visible
    -- surface. If the real list is empty (e.g. previewing while solo, or on
    -- a no-kick spec with no one else grouped), an anchor with zero visible
    -- children is literally nothing to look at or grab. Only while
    -- positioning via Unlock Mode, fabricate one placeholder bar so there's
    -- always something on screen to drag; never done during normal play.
    if unlockStubActive and #list == 0 then
        local _, myClass = UnitClass("player")
        list = { { name = "Interrupt Tracker", classTag = myClass, spellID = 0, duration = 1, endTime = 0, noAddon = true } }
    end

    local now = GetTime()
    local maxBars = cfg.maxBars or 10
    local shownCount = math.min(#list, maxBars)

    for i = 1, #bars do
        local bar = bars[i]
        local entry = (i <= maxBars) and list[i] or nil

        if entry then
            RenderBarEntry(bar, entry, cfg, now)
            bar:Show()
        else
            bar:Hide()
        end
    end

    -- NOT calling ApplyPosition() here: once a position is saved (cfg.pos),
    -- SetPoint("TOPLEFT", UIParent, "CENTER", cfg.pos.left, cfg.pos.top) is
    -- entirely size-independent -- re-applying it on every redraw did
    -- nothing useful, but DID fight Unlock Mode's live drag, snapping the
    -- frame back to its last-saved position every ~50ms while the mouse was
    -- still held down. Position is (re)applied from ApplyAll (on enable/
    -- settings change) and from Unlock Mode's own applyPos callback.
    UpdateAnchorSize(shownCount)
end

-------------------------------------------------------------------------------
--  Unlock Mode registration -- position only (mirrors HealerMana/StatusBar).
--  There's no separate window to resize: the stack is always sized to fit
--  its bars, and bar width/height are their own settings on the options
--  page, not a drag-resize handle.
-------------------------------------------------------------------------------
local unlockRegistered = false

-- Fired by EllesmereUI:RegisterUnlockModeListener below. NOT the same as
-- hooking `_G.EllesmereUnlockMode`'s OnShow/OnHide -- that frame is created
-- lazily on the FIRST time Unlock Mode is ever opened (CreateUnlockFrame in
-- EUI_UnlockMode.lua), so hooking it at login (before it exists) silently
-- never fires. The listener API is available from file-load and replays the
-- current state immediately on registration if a session is already open.
local function OnUnlockModeChanged(active)
    if active then
        local cfg = DB()
        if not cfg or not cfg.enabled then return end
        unlockStubActive = true
    else
        unlockStubActive = false
    end
    RefreshBars()
end

local function RegisterUnlock()
    if unlockRegistered then return end
    if not EllesmereUI or not EllesmereUI.RegisterUnlockElements or not EllesmereUI.MakeUnlockElement then return end
    local MK = EllesmereUI.MakeUnlockElement

    local element = MK({
        key            = "EVL_InterruptTracker",
        label          = "Interrupt Tracker",
        group          = "Voidlol",
        order          = 220,
        noResize       = true, -- no drag-resize handle / manual W-H boxes...
        allowMatchSource = true, -- ...but the Width Match button still shows and works via setWidth
        noAnchorTarget = true, -- size changes dynamically with the live bar count
        getFrame       = function() return EnsureAnchor() end,
        getSize        = function()
            if anchor then return anchor:GetWidth(), anchor:GetHeight() end
            local cfg = DB()
            return (cfg and cfg.barWidth or 200), (cfg and cfg.barHeight or 24)
        end,
        isHidden = function()
            local cfg = DB()
            return not (cfg and cfg.enabled)
        end,
        savePos  = function()
            local cfg = DB()
            if not cfg or not anchor or not anchor:GetLeft() or not anchor:GetTop() then return end
            local left, top = anchor:GetLeft(), anchor:GetTop()
            local upX, upY = UIParent:GetCenter()
            local fes = anchor:GetEffectiveScale() or 1
            local ues = UIParent:GetEffectiveScale() or 1
            local ratio = fes / ues
            cfg.pos = { left = left * ratio - upX, top = top * ratio - upY }
        end,
        loadPos  = function()
            local cfg = DB()
            return cfg and cfg.pos
        end,
        clearPos = function()
            local cfg = DB()
            if cfg then cfg.pos = nil end
        end,
        applyPos = function() ApplyPosition() end,
        -- Width Match sets a TOTAL frame width; back out the bar-width
        -- portion (total minus icon + gap) and store that, since barWidth is
        -- the actual setting. No setHeight -- height is derived from however
        -- many bars are shown, not something meaningful to match to.
        setWidth = function(_, w)
            local cfg = DB()
            if not cfg then return end
            local iconSize = cfg.barHeight or 24 -- icon is a square exactly matching the bar's own height
            cfg.barWidth = math.max(20, math.floor(w - iconSize - (cfg.iconGap or 4) + 0.5))
            ApplyLayout()
            RefreshBars()
            if EllesmereUI.NotifyElementResized then EllesmereUI.NotifyElementResized("EVL_InterruptTracker") end
        end,
    })
    EllesmereUI:RegisterUnlockElements({ element }, "EllesmereUIVoidlol")
    unlockRegistered = true
    if EllesmereUI.RegisterUnlockModeListener then
        EllesmereUI:RegisterUnlockModeListener("EllesmereUIVoidlol_InterruptTracker", OnUnlockModeChanged)
    end
end

-------------------------------------------------------------------------------
--  ADDON-MESSAGE SYNC (cross-confirmation between party members who both run
--  this addon), over chat type "PARTY".
--
--  Only a player's report about THEIR OWN kick is trusted (it's as reliable
--  as our own local reading); reports "about" someone else are never sent or
--  accepted, so there's no way for one relayed message to cascade/degrade
--  across hops. Secret-string handling for CHAT_MSG_ADDON payloads goes
--  through ScrubSecretString (defined earlier, alongside the other taint
--  workarounds).
-------------------------------------------------------------------------------
C_ChatInfo.RegisterAddonMessagePrefix(SYNC_PREFIX)

local function EncodeSyncPayload(name, classTag, spellID, baseCd, remaining)
    return table.concat({ SYNC_MESSAGE_PREFIX, name, classTag or "", tostring(spellID), tostring(baseCd), tostring(remaining) }, ";")
end

-- `msg` must already be a plain (scrubbed) string -- never feed a raw event
-- payload straight into this.
local function DecodeSyncPayload(msg)
    local tag, name, classTag, spellID, baseCd, remaining = strsplit(";", msg or "")
    if tag ~= SYNC_MESSAGE_PREFIX then return nil end
    spellID = tonumber(spellID)
    baseCd = tonumber(baseCd)
    remaining = tonumber(remaining)
    if not (name and name ~= "" and spellID and baseCd and remaining) then return nil end
    return name, classTag, spellID, baseCd, remaining
end

local function SendSyncMessage(payload)
    local cfg = DB()
    if not cfg or not cfg.syncEnabled then return end
    if not IsRealParty() then return end
    C_ChatInfo.SendAddonMessage(SYNC_PREFIX, payload, "PARTY")
end

-- Baseline self-registration: knows (and can broadcast) your own interrupt
-- spell/CD from the moment your class/spec is visible, showing it as "Ready"
-- before you've ever cast it. Without this, your own bar wouldn't appear
-- until your first kick, and a party member who receives your broadcast
-- before that would get nothing to sync against. (Assigns the forward
-- declaration made above EVENT WIRING -- also called directly on login/
-- roster-change, not just before a sync broadcast, so the local bar list is
-- correct even with sync disabled.)
AutoRegisterSelf = function()
    local name = SafeUnitName("player")
    if not name or kickRegistry[name] then return end
    local _, cls = UnitClass("player")
    local kick = cls and CLASS_INTERRUPTS[cls]
    if not kick then return end

    local specID = GetSpecForUnit("player")
    local spellID, baseCd = kick.id, kick.cd
    if specID and SPEC_NO_INTERRUPT[specID] then
        kickNoInterrupt[name] = true
        return
    elseif specID and SPEC_INTERRUPT_OVERRIDES[specID] and SPEC_INTERRUPT_OVERRIDES[specID].id then
        local ov = SPEC_INTERRUPT_OVERRIDES[specID]
        spellID, baseCd = ov.id, ov.cd
    end
    baseCd = ApplyOwnTalentCdAdjustment(spellID, baseCd, cls, specID)
    local cfg = DB()
    if spellID == 47528 and cfg and cfg.dkMindFreezeCDRTalent then
        baseCd = math.max(1, baseCd - (cfg.dkMindFreezeCDRAmount or 3))
    end

    local entry = KickRegCreate(name)
    entry.class = cls
    entry.spellID = spellID
    entry.baseCd = baseCd
    entry.cdEnd = GetTime() -- ready
end

-- Broadcasts what WE currently know about OUR OWN interrupt cooldown.
local function BroadcastOwnState()
    local cfg = DB()
    if not cfg or not cfg.syncEnabled then return end
    AutoRegisterSelf()
    local myName = SafeUnitName("player")
    local entry = myName and kickRegistry[myName]
    if not entry or not entry.spellID or entry.spellID == 0 then return end
    local remaining = math.max(0, (entry.cdEnd or 0) - GetTime())
    SendSyncMessage(EncodeSyncPayload(myName, entry.class, entry.spellID, entry.baseCd, remaining))
end

local lastQueryAt = 0
-- Asks everyone in the party to (re)send their state, so a late joiner or
-- someone who just reconnected catches up instead of waiting for the next
-- real kick.
local function RequestSync(force)
    local cfg = DB()
    if not cfg or not cfg.syncEnabled then return end
    local now = GetTime()
    if not force and (now - lastQueryAt) < SYNC_QUERY_MIN_INTERVAL then return end
    lastQueryAt = now
    SendSyncMessage(SYNC_MESSAGE_PREFIX .. "Q")
end

-- Applies a party member's self-reported kick: as reliable as our own local
-- reading, so it simply overwrites the heuristic guess.
local function ApplyRemoteKick(name, classTag, spellID, baseCd, remaining)
    name = NormalizeName(name)
    local entry = KickRegCreate(name)
    entry.class = classTag ~= "" and classTag or entry.class
    entry.spellID = spellID
    entry.baseCd = baseCd
    entry.cdEnd = GetTime() + math.max(0, remaining)
    entry.lastKickAt = entry.cdEnd - baseCd
    kickNoInterrupt[name] = nil
    if Hooks.onKickRegistryChanged then Hooks.onKickRegistryChanged() end
end

local lastRosterKey = nil

local function ComputeRosterKey()
    local names = {}
    local selfName = (GetUnitName and GetUnitName("player", true)) or UnitName("player")
    if selfName then names[#names + 1] = selfName end
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) and UnitIsPlayer(u) then
            local n = (GetUnitName and GetUnitName(u, true)) or UnitName(u)
            if n then names[#names + 1] = n end
        end
    end
    table.sort(names)
    return table.concat(names, ","):lower()
end

-- Called on login and on every roster change: debounce briefly (the roster
-- can fire this event several times in a row while it settles -- follower
-- dungeons in particular can fire GROUP_ROSTER_UPDATE many times as each
-- follower "joins"), then broadcast our own state and ask the party to do
-- the same. A genuinely new roster (someone joined/left) always asks; an
-- unchanged roster (e.g. a role change fired the event) asks throttled.
-- (Assigns the forward declaration made above EVENT WIRING.) Cancels any
-- still-pending timer from an earlier call in the same debounce window
-- instead of stacking one per event, so a burst of roster events schedules
-- exactly one broadcast, not N of them.
local pendingSyncTimer = nil
SyncOnRosterChange = function()
    local cfg = DB()
    if not cfg or not cfg.syncEnabled then return end
    if not IsRealParty() then
        lastRosterKey = nil
        if pendingSyncTimer then pendingSyncTimer:Cancel(); pendingSyncTimer = nil end
        return
    end
    local key = ComputeRosterKey()
    local isNewRoster = key ~= lastRosterKey
    lastRosterKey = key
    if pendingSyncTimer then pendingSyncTimer:Cancel() end
    pendingSyncTimer = C_Timer.NewTimer(SYNC_BROADCAST_DELAY, function()
        pendingSyncTimer = nil
        BroadcastOwnState()
        RequestSync(isNewRoster)
    end)
end

local syncFrame = CreateFrame("Frame", nil, UIParent); syncFrame:Hide()
syncFrame:SetScript("OnEvent", function(_, _, prefix, text, channel, sender)
    local cfg = DB()
    if not cfg or not cfg.syncEnabled then return end

    local okPrefix, prefixMatches = pcall(function() return prefix == SYNC_PREFIX end)
    if not okPrefix or not prefixMatches then return end
    local okChan, chanMatches = pcall(function() return channel == "PARTY" end)
    if not okChan or not chanMatches then return end

    -- Rebuild the (possibly secret) text/sender into plain strings before
    -- doing anything else with them.
    local plainText = ScrubSecretString(text)
    if not plainText then return end
    local plainSender = ScrubSecretString(sender) or sender
    local senderShort = NormalizeName(plainSender)
    if senderShort == SafeUnitName("player") then return end -- our own echo

    if plainText == (SYNC_MESSAGE_PREFIX .. "Q") then
        -- Someone (re)joined/reconnected and is asking everyone to (re)send
        -- their state; reply with a small random delay so several replies
        -- don't land in the same instant and trip the chat flood protection.
        C_Timer.After(math.random() * 0.4, BroadcastOwnState)
        return
    end

    local name, classTag, spellID, baseCd, remaining = DecodeSyncPayload(plainText)
    if not name then return end
    -- Only accept a report where the sender is describing their OWN kick.
    if NormalizeName(name) ~= senderShort then return end
    if not ALL_INTERRUPTS[spellID] then return end -- ignore garbage/foreign traffic on the prefix

    ApplyRemoteKick(name, classTag, spellID, baseCd, remaining)
end)

Hooks.onKickDetected = function(name, spellID, baseCd, cdEndTime)
    local cfg = DB()
    if cfg and cfg.syncEnabled and name and spellID and cdEndTime and name == SafeUnitName("player") then
        BroadcastOwnState()
    end
    RefreshBars()
end
Hooks.onKickRegistryChanged = function() RefreshBars() end

-------------------------------------------------------------------------------
--  Runtime enable/disable -- registers/unregisters every event frame above
--  plus the redraw ticker. Zero cost unless the module is opted into
--  (cfg.enabled), matching every other Voidlol module.
-------------------------------------------------------------------------------
local driver = CreateFrame("Frame", nil, UIParent)
local elapsed = 0

local function DriverOnUpdate(_, delta)
    elapsed = elapsed + delta
    if elapsed < REFRESH_INTERVAL then return end
    elapsed = 0
    RefreshBars()
end

local function EnableRuntime()
    playerFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "pet")
    npFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    npFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    rosterFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    rosterFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    syncFrame:RegisterEvent("CHAT_MSG_ADDON")
    elapsed = 0
    driver:SetScript("OnUpdate", DriverOnUpdate)
end

local function DisableRuntime()
    playerFrame:UnregisterAllEvents()
    npFrame:UnregisterAllEvents()
    rosterFrame:UnregisterAllEvents()
    syncFrame:UnregisterAllEvents()
    driver:SetScript("OnUpdate", nil)
end

-------------------------------------------------------------------------------
--  Apply (called on settings change / login)
-------------------------------------------------------------------------------
local function ApplyAll()
    local cfg = DB()
    if not cfg or not cfg.enabled then
        DisableRuntime()
        if anchor then anchor:Hide() end
        unlockStubActive = false
        return
    end

    EnsureAnchor()
    EnsureBars(cfg.maxBars or 10)
    ApplyPosition()
    ApplyLayout()
    EnableRuntime()
    RegisterUnlock()

    AutoRegisterParty()
    AutoRegisterSelf()
    SyncOnRosterChange()

    if EllesmereUI.IsUnlockModeActive and EllesmereUI.IsUnlockModeActive() then
        unlockStubActive = true
    else
        unlockStubActive = false
    end

    RefreshBars()
end
EVL.ApplyInterruptTracker = ApplyAll

-------------------------------------------------------------------------------
--  Options-page preview -- two standalone sample bars (one ready, one on
--  cooldown with a randomized hit/miss badge), independent of Enabled/group
--  status, styled via the exact same StyleBar/RenderBarEntry every live bar
--  uses, so a settings change is visible immediately without grouping up.
--  EUI_Voidlol_Options.lua calls EnsurePreviewGroup once (to get the host
--  frame) and RefreshPreviewGroup on every settings change / page open.
-------------------------------------------------------------------------------
local PREVIEW_COUNT = 2
local previewGroup -- { frame, bars = {} }
local PREVIEW_NAMES = {
    "Thrall", "Jaina", "Sylvanas", "Varian", "Illidan", "Tyrande",
    "Uther", "Malfurion", "Arthas", "Vol'jin", "Baine", "Genn",
}
-- Every trackable class token (built once from CLASS_INTERRUPTS, which
-- covers all 13 classes) so the preview isn't tied to two hardcoded classes.
local PREVIEW_CLASS_TOKENS = {}
for cls in pairs(CLASS_INTERRUPTS) do
    PREVIEW_CLASS_TOKENS[#PREVIEW_CLASS_TOKENS + 1] = cls
end

-- Picks `count` distinct random entries from `pool` (so the two preview
-- bars don't show the exact same class/name as each other). Gives up on
-- staying distinct after a few tries -- harmless if `pool` is ever smaller
-- than `count`.
local function PickDistinct(pool, count)
    local picked, used = {}, {}
    for _ = 1, count do
        local idx, tries = math.random(1, #pool), 0
        while used[idx] and tries < 20 do
            idx = math.random(1, #pool)
            tries = tries + 1
        end
        used[idx] = true
        picked[#picked + 1] = pool[idx]
    end
    return picked
end

function EVL.InterruptTracker_EnsurePreviewGroup(parent)
    if not previewGroup then
        previewGroup = { frame = CreateFrame("Frame", nil, parent), bars = {} }
    else
        previewGroup.frame:SetParent(parent)
    end
    for i = 1, PREVIEW_COUNT do
        if not previewGroup.bars[i] then
            previewGroup.bars[i] = CreateBar(previewGroup.frame)
        end
    end
    return previewGroup.frame
end

-- Exposes the two persistent preview bar frames (each with .icon/.nameText/
-- .timeText, same shape as a live bar) so EUI_Voidlol_Options.lua can attach
-- click-to-navigate hit overlays directly to their sub-parts.
function EVL.InterruptTracker_GetPreviewBars()
    return previewGroup and previewGroup.bars
end

function EVL.InterruptTracker_RefreshPreviewGroup()
    if not previewGroup then return 0, 0 end
    local cfg = DB()
    if not cfg then return 0, 0 end

    local iconSize = cfg.barHeight or 24
    local barWidth = cfg.barWidth or 200
    local fontPath = GetFontPath(cfg.fontFace)
    local PP = EllesmereUI and EllesmereUI.PP
    local thickness = cfg.borderThickness
    if thickness == nil then thickness = 1 end

    for i = 1, PREVIEW_COUNT do
        local bar = previewGroup.bars[i]
        bar:ClearAllPoints()
        StyleBar(bar, cfg, iconSize, barWidth, fontPath, thickness, PP)
        if i == 1 then
            bar:SetPoint("TOPLEFT", previewGroup.frame, "TOPLEFT",
                (cfg.iconPosition == "right") and 0 or (iconSize + (cfg.iconGap or 4)), 0)
        else
            bar:SetPoint("TOPLEFT", previewGroup.bars[i - 1], "BOTTOMLEFT", 0, -(cfg.barSpacing or 6))
        end
        bar:Show()
    end

    local now = GetTime()
    local classes = PickDistinct(PREVIEW_CLASS_TOKENS, 2)
    local names = PickDistinct(PREVIEW_NAMES, 2)
    local readyKick = CLASS_INTERRUPTS[classes[1]]
    local cdKick = CLASS_INTERRUPTS[classes[2]]

    RenderBarEntry(previewGroup.bars[1], {
        name = names[1], classTag = classes[1], spellID = readyKick.id,
        duration = readyKick.cd, endTime = now, noAddon = false,
    }, cfg, now)

    RenderBarEntry(previewGroup.bars[2], {
        name = names[2], classTag = classes[2], spellID = cdKick.id,
        duration = cdKick.cd, endTime = now + cdKick.cd * 0.7, noAddon = false,
        kickResult = (math.random() < 0.5) and "hit" or "miss",
    }, cfg, now)

    local totalW = barWidth + iconSize + (cfg.iconGap or 4)
    local totalH = (cfg.barHeight or 24) * PREVIEW_COUNT + (cfg.barSpacing or 6) * (PREVIEW_COUNT - 1)
    previewGroup.frame:SetSize(math.max(1, totalW), math.max(1, totalH))
    return totalW, totalH
end

-------------------------------------------------------------------------------
--  Bootstrap
-------------------------------------------------------------------------------
function EVL.InitInterruptTracker()
    ApplyAll()
end
