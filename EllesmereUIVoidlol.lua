-------------------------------------------------------------------------------
--  EllesmereUIVoidlol.lua
--  Custom EllesmereUI module. Features are added here as they're implemented.
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...

ns.EVL = ns.EVL or {}
local EVL = ns.EVL

local EBS = EllesmereUI.Lite.NewAddon("EllesmereUIVoidlol")
EVL.EBS = EBS

local defaults = {
    profile = {
        voidlol = {
            enabled = false,

            qol = {
                actualDragonridingVisibility = false,
                suppressAutoPlayed = false,
                runesSpecColored = false,

                debuffNotDispellableColor = false,
                debuffNotDispellableColorR = 0.5,
                debuffNotDispellableColorG = 0.5,
                debuffNotDispellableColorB = 0.5,

                mirrorCdmCooldownsVisibilityToBars = false,

                statusBar = {
                    enabled = false,
                    spacing = 12,
                    pos     = nil,
                    hideWhileChatting = false,

                    -- 0 = auto-fit to content; never narrower than that
                    -- regardless of this value (see RefreshStatusBar).
                    width    = 0,
                    vPadding = 3,

                    fontFace = "__global",
                    fontSize = 13,
                    outline  = true,
                    labelColorR = 0.6,
                    labelColorG = 0.6,
                    labelColorB = 0.6,

                    bgEnabled = false,
                    bgColorR  = 0,
                    bgColorG  = 0,
                    bgColorB  = 0,
                    bgOpacity = 50,

                    -- fps block shows BOTH FPS and latency ("FPS: 134  MS: 44") --
                    -- one block, not two.
                    blocks = {
                        fps        = { enabled = true,  order = 1, useWorldLatency = false },
                        durability = { enabled = true,  order = 2 },
                        clock      = { enabled = false, order = 3 },
                    },
                },
            },

            quickFocus = {
                enabled    = false,
                modifier   = "shift",  -- "shift" | "ctrl" | "alt"
                button     = "BUTTON1",
                setMark    = false,
                safeMark   = false,
                markNumber = 3,

                announceFocusMarkOnReadyCheck = false,
                announceInParty               = true,
                announceInRaid                = true,
            },

            combatText = {
                enabled = false, -- master switch; per-frame enabled flags below still apply on top

                incomingDamage = {
                    enabled      = false,
                    pos          = nil,
                    align        = "CENTER", -- "LEFT" | "CENTER" | "RIGHT"
                    font         = "__global",
                    outline      = true,
                    fontSize     = 22,
                    rowsLimit    = 5,
                    fadeStart    = 1.0,
                    fadeDuration = 0.5,
                    colorByType  = false, -- color by damage school once the real engine lands; no manual color
                    prefix       = "", -- only applied to numeric amounts, never to Absorb/Dodge/Parry/etc.
                },
                incomingHeal = {
                    enabled      = false,
                    pos          = nil,
                    align        = "CENTER",
                    font         = "__global",
                    outline      = true,
                    fontSize     = 22,
                    rowsLimit    = 5,
                    fadeStart    = 1.0,
                    fadeDuration = 0.5,
                    textR        = 0.25,
                    textG        = 1,
                    textB        = 0.35,
                    prefix       = "",
                },
            },

            castbar = {
                enabled                   = false,

                detachIcon                = false,
                iconSize                  = 32,
                iconBorderWidth           = 1,
                detachAnchor              = "RIGHT", -- "RIGHT" | "LEFT" | "TOP" | "BOTTOM"
                detachXOffset             = 8,
                detachYOffset             = 0,

                desaturateUninterruptible = true,

                showUninterruptibleText   = true,
                uninterruptibleText       = "X",
                uninterruptibleTextFont   = "__global",
                uninterruptibleTextSize   = 12,
                uninterruptibleTextR      = 1,
                uninterruptibleTextG      = 0.2,
                uninterruptibleTextB      = 0.2,

                overlayMode               = false,
            },

            -- Master enabled switch is shared; every visual setting is
            -- independent per frame (party/raid), including position.
            healerMana = {
                enabled = false,

                party = {
                    enabled            = true,
                    showIcon           = true,
                    iconSize           = 24,
                    oneLineMode        = false, -- only relevant while showIcon is off
                    nameMaxLength      = 0,     -- 0 = unlimited
                    fontFace           = "__global",
                    fontSize           = 12,
                    useCustomManaColor = false, -- off = plain white
                    manaColorR         = 1,
                    manaColorG         = 1,
                    manaColorB         = 1,
                    pos                = nil,
                },
                raid = {
                    enabled            = true,
                    showIcon           = true,
                    iconSize           = 24,
                    oneLineMode        = false,
                    nameMaxLength      = 0,
                    fontFace           = "__global",
                    fontSize           = 12,
                    useCustomManaColor = false,
                    manaColorR         = 1,
                    manaColorG         = 1,
                    manaColorB         = 1,
                    raidGrowDirection  = "VERTICAL", -- "VERTICAL" | "HORIZONTAL"
                    pos                = nil,
                },
            },

            interruptTracker = {
                enabled = false,

                -- ---- Bar appearance ----
                barWidth        = 200,
                barHeight       = 24,
                barSpacing      = 6,
                maxBars         = 10,
                iconPosition    = "left", -- "left" | "right"
                iconGap         = 4,
                reverseFill     = false,
                barTexture      = "Blizzard", -- "Blizzard" or "sm:<LibSharedMedia name>"
                fontFace        = "__global",
                fontSize        = 12,
                textColorR      = 1,
                textColorG      = 1,
                textColorB      = 1,
                barBgColorR     = 0.08,
                barBgColorG     = 0.08,
                barBgColorB     = 0.08,
                barBgColorA     = 0.95,
                borderThickness = 1, -- 0 = no border

                -- ---- Position (dragged via EllesmereUI Unlock Mode) ----
                pos             = nil,

                -- ---- Bar colors by cooldown state ----
                readyColorR          = 0.0,
                readyColorG          = 0.78,
                readyColorB          = 0.2,
                readyColorA          = 1,
                readyTextColorR      = 0.2,
                readyTextColorG      = 1,
                readyTextColorB      = 0.2,
                keepReadyClassColor  = false,
                onCooldownColorMul   = 0.7,
                onCooldownAlpha      = 0.9,
                noAddonColorR        = 0.2,
                noAddonColorG        = 0.2,
                noAddonColorB        = 0.2,
                noAddonOpacity       = 80,
                noAddonTextColorR    = 0.6,
                noAddonTextColorG    = 0.6,
                noAddonTextColorB    = 0.6,

                -- ---- Name text color, per ready/cooldown state ----
                -- mode: "custom" (use the R/G/B below) | "class" (tracked player's class color)
                nameColorReadyMode      = "custom",
                nameColorReadyR         = 1,
                nameColorReadyG         = 1,
                nameColorReadyB         = 1,
                nameColorCooldownMode   = "custom",
                nameColorCooldownR      = 1,
                nameColorCooldownG      = 1,
                nameColorCooldownB      = 1,

                -- ---- Visibility rules ----
                onlyInInstances         = false,
                hideInDungeons          = false,
                maxGroupSizeToShow      = 5,
                showNoAddonPlaceholders = true,

                -- ---- Talent-based cooldown accuracy (own player only) ----
                enableTalentAdjustments = true,
                dkMindFreezeCDRTalent   = false,
                dkMindFreezeCDRAmount   = 3,

                -- ---- Addon-message cross-confirmation sync (party) ----
                syncEnabled = true,
            },
        },
    },
}

-------------------------------------------------------------------------------
--  DB accessor (shared with all Voidlol sub-files)
-------------------------------------------------------------------------------
function EVL.DB()
    return EBS.db and EBS.db.profile and EBS.db.profile.voidlol
end

-------------------------------------------------------------------------------
--  Apply
-------------------------------------------------------------------------------
local function ApplyAll()
    local cfg = EVL.DB()
    if not cfg then return end
    -- Interrupt Tracker: force-disabled, not reliable enough to ship right
    -- now (see EUI_Voidlol_Options.lua's nav-list comment). Stomping the
    -- saved flag here means it stays off even for a profile that had it
    -- enabled before this was pulled, and EVL.ApplyInterruptTracker/
    -- InitInterruptTracker are deliberately never called below.
    if cfg.interruptTracker then cfg.interruptTracker.enabled = false end
    if EVL.ApplyQoL then EVL.ApplyQoL() end
    if EVL.ApplyTweaks then EVL.ApplyTweaks() end
    if EVL.ApplyStatusBar then EVL.ApplyStatusBar() end
    if EVL.ApplyQuickFocus then EVL.ApplyQuickFocus() end
    if EVL.ApplyCombatText then EVL.ApplyCombatText() end
    if EVL.ApplyCastbar then EVL.ApplyCastbar() end
    if EVL.ApplyHealerMana then EVL.ApplyHealerMana() end
end
EVL.ApplyAll = ApplyAll
_G._EVL_ApplyAll = ApplyAll

-------------------------------------------------------------------------------
--  Lifecycle
-------------------------------------------------------------------------------
function EBS:OnInitialize()
    EBS.db = EllesmereUI.Lite.NewDB("EllesmereUIVoidlolDB", defaults)

    -- Global bridge for options <-> main communication
    _G._EVL_DB = EBS.db
end

function EBS:OnEnable()
    ApplyAll()
    if EVL.InitCastbarHooks then EVL.InitCastbarHooks() end
    if EVL.InitHealerMana then EVL.InitHealerMana() end
end
