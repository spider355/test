-- =============================================================================
--  HERMOD GUI MODULE  [v2.1]
--  Config display + live status overlay.
--  Uses ONLY API.DrawTable — no gui_lib dependency.
--
--  Config window auto-starts after a countdown, showing current settings.
--  Edit the DEFAULTS table below to change your preferences before running.
-- =============================================================================

local API = require("api")

-- ── DEFAULT CONFIG ────────────────────────────────────────────────────────────
-- Edit these values to match your setup before running.
local DEFAULTS = {
    -- General
    waitForFullHp        = true,
    useCurses            = true,    -- true = Soul Split/Deflect Melee; false = Standard prayers
    hpThresholdPct       = 50,      -- eat food when HP drops below this %
    hpCriticalPct        = 30,      -- emergency eat below this %
    hpSpecialPct         = 65,      -- use special restore (e.g. Excalibur) below this %
    prayerThresholdPct   = 20,      -- drink prayer restore below this %
    prayerCriticalPct    = 10,      -- emergency prayer restore below this %

    -- War's Retreat loop (set false if you want to start already inside the instance)
    useWarsRetreat       = true,
    bankPin              = "",      -- your 4-digit bank PIN as a string e.g. "1234"
    prayAtAltar          = true,
    useAdrenCrystal      = false,   -- requires 1,000 boss KC to unlock — leave false until then
    summonConjures       = true,    -- resummons Ghost + Skeleton + Zombie before portal
    surgeDiveChance      = 50,      -- 0-100: % chance to use Surge when navigating War's Retreat
    minHpToEnter         = 80,      -- don't enter portal below this HP %
    minPrayerToEnter     = 50,      -- don't enter portal below this prayer %

    -- Loot toggles
    lootHermodicPlate    = true,    -- ID 49394, ~1/10 drop — primary farm target
    lootArmourSpike      = true,    -- ID ~49395, 1/2000
    lootBigBones         = false,
    lootCoins            = true,
    lootOtherDrops       = true,    -- catch-all for extra IDs added in ALL_LOOT (main.lua)
    trackGp              = true,    -- estimate session GP from known drop values

    -- Debug logging (printed to MemoryError console)
    debugMain            = false,
    debugTimer           = false,
    debugPlayer          = false,
    debugPrayer          = false,
    debugWars            = false,
}

-- How many seconds to display the config summary before auto-starting.
-- Set to 0 to start immediately.
local AUTO_START_DELAY = 8

-- ── MODULE ────────────────────────────────────────────────────────────────────
local GuiModule = {}
GuiModule.__index = GuiModule

function GuiModule.new(overrides)
    local self = setmetatable({}, GuiModule)
    self._cfg  = {}
    for k, v in pairs(DEFAULTS) do self._cfg[k] = v end
    if overrides then
        for k, v in pairs(overrides) do self._cfg[k] = v end
    end
    self._started    = false
    self._startedAt  = nil   -- os.time() when drawConfig was first called
    return self
end

function GuiModule:isStarted()  return self._started end
function GuiModule:getConfig()  return self._cfg     end

-- ── CONFIG DISPLAY ────────────────────────────────────────────────────────────
-- Shows a DrawTable summary of the current config and counts down to auto-start.
-- Called every tick from main.lua until isStarted() returns true.
function GuiModule:drawConfig()
    local cfg = self._cfg

    -- Start countdown timer on first call
    if not self._startedAt then
        self._startedAt = os.time()
        print("[Hermod] Config loaded. Edit DEFAULTS in hermod/gui.lua to change settings.")
        print(string.format("[Hermod] Auto-starting in %d seconds...", AUTO_START_DELAY))
        self:_printConfig(cfg)
    end

    local remaining = AUTO_START_DELAY - (os.time() - self._startedAt)

    API.DrawTable({
        { "Hermod v2.1 — Starting in " .. tostring(math.max(0, remaining)) .. "s", "" },
        { "══════════════", "══════════════" },
        { "MODE",          cfg.useWarsRetreat and "Wars Retreat loop" or "Manual (in-instance)" },
        { "Prayers",       cfg.useCurses and "Curses (SS/Deflect)" or "Standard" },
        { "Wait full HP",  tostring(cfg.waitForFullHp) },
        { "──────────────", "──────────────" },
        { "HP threshold",  tostring(cfg.hpThresholdPct) .. "%" },
        { "HP critical",   tostring(cfg.hpCriticalPct)  .. "%" },
        { "Prayer thresh", tostring(cfg.prayerThresholdPct) .. "%" },
        { "──────────────", "──────────────" },
        { "Altar",         tostring(cfg.prayAtAltar) },
        { "Adrenaline X",  tostring(cfg.useAdrenCrystal) },
        { "Conjures",      tostring(cfg.summonConjures) },
        { "Surge chance",  tostring(cfg.surgeDiveChance) .. "%" },
        { "Min HP enter",  tostring(cfg.minHpToEnter) .. "%" },
        { "──────────────", "──────────────" },
        { "Loot plate",    tostring(cfg.lootHermodicPlate) },
        { "Loot spike",    tostring(cfg.lootArmourSpike) },
        { "Loot coins",    tostring(cfg.lootCoins) },
        { "Track GP",      tostring(cfg.trackGp) },
        { "══════════════", "══════════════" },
        { "Edit settings", "hermod/gui.lua → DEFAULTS" },
    })

    if remaining <= 0 then
        self._started = true
        print("[Hermod] Starting!")
    end
end

-- ── LIVE STATUS OVERLAY ───────────────────────────────────────────────────────
function GuiModule:drawStatus(stats)
    local s  = stats or {}
    local t  = s.sessionSecs or 0
    local rt = string.format("%02d:%02d:%02d",
        math.floor(t / 3600), math.floor((t % 3600) / 60), t % 60)
    local kph = t > 60 and string.format("%.1f/hr", (s.killCount or 0) / (t / 3600)) or "—"
    local gp  = self._cfg.trackGp and (commify(s.estimatedGP or 0) .. " gp") or "off"

    API.DrawTable({
        { "⚔  Hermod, Spirit of War",  ""                                          },
        { "State",       s.state or "—"                                             },
        { "─────────",   "─────────"                                                },
        { "Kills",       tostring(s.killCount or 0) .. "  (" .. kph .. ")"         },
        { "Runtime",     rt                                                          },
        { "Est. GP",     gp                                                          },
        { "─────────",   "─────────"                                                },
        { "HP",          string.format("%d%%", s.hp or 0)                           },
        { "Prayer",      string.format("%d%%", s.prayer or 0)                       },
        { "─────────",   "─────────"                                                },
        { "Hermod",      (s.hermodAlive and "Alive") or "Dead / absent"             },
        { "Phantoms",    tostring(s.phantomCount or 0)                              },
        { "Last target", s.lastTarget or "—"                                        },
    })
end

-- ── PRIVATE ───────────────────────────────────────────────────────────────────
function GuiModule:_printConfig(cfg)
    print("──────────────────────────────────────────")
    print(string.format("  Mode:          %s", cfg.useWarsRetreat and "Wars Retreat loop" or "Manual"))
    print(string.format("  Prayers:       %s", cfg.useCurses and "Curses" or "Standard"))
    print(string.format("  HP thresh:     %d%%  (crit: %d%%)", cfg.hpThresholdPct, cfg.hpCriticalPct))
    print(string.format("  Prayer thresh: %d%%  (crit: %d%%)", cfg.prayerThresholdPct, cfg.prayerCriticalPct))
    print(string.format("  Altar:         %s  |  Adrenaline Crystal: %s", tostring(cfg.prayAtAltar), tostring(cfg.useAdrenCrystal)))
    print(string.format("  Conjures:      %s  |  Surge chance: %d%%", tostring(cfg.summonConjures), cfg.surgeDiveChance))
    print(string.format("  Loot plate:    %s  |  Track GP: %s", tostring(cfg.lootHermodicPlate), tostring(cfg.trackGp)))
    print("──────────────────────────────────────────")
end

function commify(n)
    local s = tostring(math.floor(n or 0))
    local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return r:gsub("^,", "")
end

return GuiModule
