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

                statusBar = {
                    enabled = false,
                    spacing = 12,
                    pos     = nil,

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
                enabled = true, -- master switch; per-frame enabled flags below still apply on top

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
                enabled                   = true,

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

            healerMana = {
                enabled                   = false,

                showInParty               = true,
                showInRaid                = true,
                raidGrowDirection         = "VERTICAL", -- "VERTICAL" | "HORIZONTAL"

                showIcon                  = true,
                iconSize                  = 24,
                nameMaxLength             = 0, -- 0 = unlimited

                fontFace                  = "__global",
                fontSize                  = 12,
                useCustomManaColor        = false, -- off = red(0%)-to-green(100%) gradient
                manaColorR                = 1,
                manaColorG                = 1,
                manaColorB                = 1,

                partyPos                  = nil,
                raidPos                   = nil,
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
    if EVL.ApplyQoL then EVL.ApplyQoL() end
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
