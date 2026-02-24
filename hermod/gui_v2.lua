-- =============================================================================
--  HERMOD GUI MODULE  [v2.0]
--  Tabbed config window + live status overlay.
--  Mirrors Sonson's Rasial GUI style.
--
--  TABS:
--    General       — HP/prayer thresholds, prayer type
--    War's Retreat — full prep loop options
--    Player Manager— recommended inventory reference
--    Loot          — per-drop toggles + GP tracking
--    Debug         — per-module log verbosity
-- =============================================================================

local API  = require("api")

-- ── Try to load Sanson's GUI lib; fall back to plain DrawTable if absent ─────
local GLib = nil
local ok, loaded = pcall(require, "core/gui_lib")
if ok then GLib = loaded end

-- ── DEFAULT CONFIG ────────────────────────────────────────────────────────────
local DEFAULTS = {
    -- General
    waitForFullHp        = true,
    useCurses            = true,    -- true = Curses (Soul Split); false = Standard
    hpThresholdPct       = 50,
    hpCriticalPct        = 30,
    hpSpecialPct         = 65,
    prayerThresholdPct   = 20,
    prayerCriticalPct    = 10,

    -- War's Retreat
    useWarsRetreat       = true,
    bankPin              = "",
    prayAtAltar          = true,
    useAdrenCrystal      = true,
    summonConjures       = true,
    surgeDiveChance      = 50,
    minHpToEnter         = 80,
    minPrayerToEnter     = 50,

    -- Loot
    lootHermodicPlate    = true,
    lootArmourSpike      = true,
    lootBigBones         = false,
    lootCoins            = true,
    lootOtherDrops       = true,
    trackGp              = true,

    -- Debug
    debugMain            = false,
    debugTimer           = false,
    debugPlayer          = false,
    debugPrayer          = false,
    debugWars            = false,
}

-- ── MODULE ────────────────────────────────────────────────────────────────────
local GuiModule = {}
GuiModule.__index = GuiModule

function GuiModule.new(overrides)
    local self  = setmetatable({}, GuiModule)
    self._cfg   = {}
    for k, v in pairs(DEFAULTS) do self._cfg[k] = v end
    if overrides then
        for k, v in pairs(overrides) do self._cfg[k] = v end
    end
    self._started   = false
    self._activeTab = 1
    self._warnings  = {}
    return self
end

function GuiModule:isStarted()  return self._started end
function GuiModule:getConfig()  return self._cfg     end

-- ── CONFIG WINDOW ─────────────────────────────────────────────────────────────
-- Called every tick until user clicks Start.
-- Uses Sanson's GLib if available, otherwise a minimal ImGui fallback.
function GuiModule:drawConfig()
    local cfg = self._cfg

    if GLib then
        self:_drawWithGLib(cfg)
    else
        self:_drawFallback(cfg)
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Full GLib-powered tabbed GUI (requires core/gui_lib.lua from Sanson's suite)
-- ────────────────────────────────────────────────────────────────────────────
function GuiModule:_drawWithGLib(cfg)
    GLib.BeginWindow("Hermod, the Spirit of War  [v2.0]", 480, 540)
    GLib.Title("⚔  Hermod, the Spirit of War", "sub", "Automated farming script")
    GLib.Separator()
    GLib.Spacing()

    if GLib.BeginTabBar("HermodCfg") then

        -- ── General ──────────────────────────────────────────────────────────
        if GLib.Tab("General") then
            GLib.Spacing()
            GLib.SectionHeader("Combat")
            cfg.waitForFullHp = GLib.Checkbox("Wait for full HP before entering", cfg.waitForFullHp)
            cfg.useCurses     = GLib.Checkbox("Using Curses  (Soul Split / Deflect Melee)", cfg.useCurses)
            GLib.Spacing()
            GLib.SectionHeader("Health Thresholds")
            cfg.hpThresholdPct = GLib.SliderInt("Eat food at HP (%)",      cfg.hpThresholdPct, 10, 90)
            cfg.hpCriticalPct  = GLib.SliderInt("Emergency eat HP (%)",    cfg.hpCriticalPct,  5,  60)
            cfg.hpSpecialPct   = GLib.SliderInt("Special restore HP (%)",  cfg.hpSpecialPct,   20, 95)
            GLib.Spacing()
            GLib.SectionHeader("Prayer Thresholds")
            cfg.prayerThresholdPct = GLib.SliderInt("Drink restore at prayer (%)",  cfg.prayerThresholdPct, 5, 60)
            cfg.prayerCriticalPct  = GLib.SliderInt("Emergency restore prayer (%)", cfg.prayerCriticalPct,  2, 40)
            GLib.EndTab()
        end

        -- ── War's Retreat ─────────────────────────────────────────────────────
        if GLib.Tab("War's Retreat") then
            GLib.Spacing()
            cfg.useWarsRetreat = GLib.Checkbox("Enable full War's Retreat loop", cfg.useWarsRetreat)
            GLib.Spacing()
            if cfg.useWarsRetreat then
                GLib.SectionHeader("Bank & Preparation")
                cfg.bankPin         = GLib.InputText("Bank PIN (blank if none)", cfg.bankPin)
                cfg.prayAtAltar     = GLib.Checkbox("Pray at Altar of War", cfg.prayAtAltar)
                cfg.useAdrenCrystal = GLib.Checkbox("Use Adrenaline Crystal (requires 1k boss kills)", cfg.useAdrenCrystal)
                cfg.summonConjures  = GLib.Checkbox("Resummon conjures (Ghost + Skeleton + Zombie)", cfg.summonConjures)
                GLib.Spacing()
                GLib.SectionHeader("Navigation")
                cfg.surgeDiveChance = GLib.SliderInt("Surge/Dive chance (%)", cfg.surgeDiveChance, 0, 100)
                GLib.Spacing()
                GLib.SectionHeader("Minimum Stats Before Entering Portal")
                cfg.minHpToEnter     = GLib.SliderInt("Minimum HP (%)",     cfg.minHpToEnter,     30, 100)
                cfg.minPrayerToEnter = GLib.SliderInt("Minimum Prayer (%)", cfg.minPrayerToEnter, 10, 100)
                GLib.Spacing()
                GLib.Text("NOTE: Attune a portal in War's Retreat to Hermod")
                GLib.Text("      before starting the script.")
            else
                GLib.Text("Manual mode: start the script already inside")
                GLib.Text("Hermod's instance. Script will wait for him to spawn.")
            end
            GLib.EndTab()
        end

        -- ── Player Manager ────────────────────────────────────────────────────
        if GLib.Tab("Player") then
            GLib.Spacing()
            GLib.SectionHeader("Recommended Inventory")
            GLib.Text("Food (normal):     Blue/Green Blubber Jellyfish")
            GLib.Text("Food (emergency):  Guthix Rest Flask")
            GLib.Text("Special HP:        Enhanced Excalibur")
            GLib.Text("Prayer restore:    Super Restore Flask")
            GLib.Text("Special prayer:    Ancient Elven Ritual Shard")
            GLib.Spacing()
            GLib.SectionHeader("Consumables")
            GLib.Text("Elder Overload Salve, Adrenaline Renewal,")
            GLib.Text("Vulnerability Bomb, Binding Contract (Ripper)")
            GLib.Spacing()
            GLib.SectionHeader("Conjures (if enabled)")
            GLib.Text("Ghost Familiar, Skeleton Warrior, Putrid Zombie")
            GLib.Text("abilities must be on your action bar.")
            GLib.EndTab()
        end

        -- ── Loot ─────────────────────────────────────────────────────────────
        if GLib.Tab("Loot") then
            GLib.Spacing()
            GLib.SectionHeader("Items to Pick Up")
            cfg.lootHermodicPlate = GLib.Checkbox("Hermodic plate       (ID 49394 — ~1/10)",    cfg.lootHermodicPlate)
            cfg.lootArmourSpike   = GLib.Checkbox("Hermod's armour spike (ID ~49395 — 1/2000)",  cfg.lootArmourSpike)
            cfg.lootCoins         = GLib.Checkbox("Coins",                                        cfg.lootCoins)
            cfg.lootBigBones      = GLib.Checkbox("Big bones",                                    cfg.lootBigBones)
            cfg.lootOtherDrops    = GLib.Checkbox("Other items in ALL_LOOT table (main.lua)",     cfg.lootOtherDrops)
            GLib.Spacing()
            GLib.SectionHeader("Statistics")
            cfg.trackGp = GLib.Checkbox("Track estimated GP/session", cfg.trackGp)
            GLib.Spacing()
            GLib.Text("Verify IDs with MemoryError's Ground Items overlay.")
            GLib.EndTab()
        end

        -- ── Debug ─────────────────────────────────────────────────────────────
        if GLib.Tab("Debug") then
            GLib.Spacing()
            GLib.SectionHeader("Console Logging  (print to MemoryError console)")
            cfg.debugMain   = GLib.Checkbox("Main script flow",        cfg.debugMain)
            cfg.debugTimer  = GLib.Checkbox("Timer / action execution", cfg.debugTimer)
            cfg.debugPlayer = GLib.Checkbox("Player Manager",           cfg.debugPlayer)
            cfg.debugPrayer = GLib.Checkbox("Prayer Flicker",           cfg.debugPrayer)
            cfg.debugWars   = GLib.Checkbox("War's Retreat navigation", cfg.debugWars)
            GLib.EndTab()
        end

        GLib.EndTabBar()
    end

    -- Warnings
    self:_buildWarnings()
    if #self._warnings > 0 then
        GLib.Spacing()
        GLib.Separator()
        for _, w in ipairs(self._warnings) do
            GLib.TextColored("⚠ " .. w, 1, 0.6, 0.2, 1)
        end
        GLib.Spacing()
    end

    GLib.Separator()
    GLib.Spacing()
    if GLib.Button("▶  Start", 180, 36) then self._started = true end
    GLib.SameLine()
    if GLib.Button("✕  Cancel", 100, 36) then API.Write_LoopyLoop(false) end
    GLib.EndWindow()
end

-- ────────────────────────────────────────────────────────────────────────────
-- Minimal fallback: plain DrawTable-based window when gui_lib is absent.
-- The user can still start by enabling a "ready" flag via a hardcoded check,
-- OR we just auto-start after a short delay so the script still runs.
-- ────────────────────────────────────────────────────────────────────────────
function GuiModule:_drawFallback(cfg)
    -- Show a status table and auto-start after 5 seconds so the script
    -- doesn't hang forever if gui_lib is missing.
    if not self._fallbackStart then
        self._fallbackStart = os.time()
        print("[Hermod] gui_lib not found — using defaults. Auto-starting in 5s.")
        print("[Hermod] Edit DEFAULTS in hermod/gui.lua to change config before running.")
    end

    local remaining = 5 - (os.time() - self._fallbackStart)

    API.DrawTable({
        { "Hermod v2.0 — Config GUI",   "" },
        { "gui_lib.lua",   "NOT FOUND (using defaults)" },
        { "Auto-starting in",  tostring(math.max(0, remaining)) .. "s" },
        { "──────────────", "──────────────" },
        { "Wars Retreat",  tostring(cfg.useWarsRetreat) },
        { "Use Curses",    tostring(cfg.useCurses) },
        { "Eat at HP %",   tostring(cfg.hpThresholdPct) },
        { "Prayer % ",     tostring(cfg.prayerThresholdPct) },
        { "Loot plate",    tostring(cfg.lootHermodicPlate) },
    })

    if remaining <= 0 then
        self._started = true
    end
end

-- ── LIVE STATUS OVERLAY ───────────────────────────────────────────────────────
-- stats table matches buildStats() in main.lua
function GuiModule:drawStatus(stats)
    local s   = stats or {}
    local t   = s.sessionSecs or 0
    local rt  = string.format("%02d:%02d:%02d",
        math.floor(t/3600), math.floor((t%3600)/60), t%60)
    local kph = t > 0 and string.format("%.1f/hr", (s.killCount or 0) / (t/3600)) or "—"
    local gp  = self._cfg.trackGp and commify(s.estimatedGP or 0) .. " gp" or "disabled"

    API.DrawTable({
        { "⚔  Hermod, Spirit of War",  ""  },
        { "State",        s.state or "—"                                     },
        { "─────────",    "─────────"                                         },
        { "Kills",        tostring(s.killCount or 0) .. "  (" .. kph .. ")"  },
        { "Runtime",      rt                                                  },
        { "Est. GP",      gp                                                  },
        { "─────────",    "─────────"                                         },
        { "HP",           string.format("%d%%", s.hp or 0)                   },
        { "Prayer",       string.format("%d%%", s.prayer or 0)               },
        { "─────────",    "─────────"                                         },
        { "Hermod",       s.hermodAlive and "Alive" or "Dead / absent"       },
        { "Phantoms",     tostring(s.phantomCount or 0)                      },
        { "Last target",  s.lastTarget or "—"                                },
    })
end

-- ── PRIVATE ───────────────────────────────────────────────────────────────────
function GuiModule:_buildWarnings()
    self._warnings = {}
    local c = self._cfg
    if c.hpCriticalPct >= c.hpThresholdPct then
        table.insert(self._warnings, "Emergency HP % should be lower than normal HP %")
    end
    if c.prayerCriticalPct >= c.prayerThresholdPct then
        table.insert(self._warnings, "Emergency prayer % should be lower than normal prayer %")
    end
    if c.useAdrenCrystal then
        table.insert(self._warnings, "Adrenaline Crystal needs 1,000 boss kills to unlock")
    end
    if c.summonConjures then
        table.insert(self._warnings, "Conjure abilities must be on your action bar")
    end
end

function commify(n)
    local s = tostring(math.floor(n or 0))
    local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return r:gsub("^,", "")
end

return GuiModule
