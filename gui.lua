-- =============================================================================
--  HERMOD GUI MODULE
--  Sanson-style tabbed config GUI using MemoryError's ImGui wrapper.
--
--  TABS:
--    General       — health/prayer thresholds, wait-for-HP, food/restore items
--    War's Retreat — bank pin, adrenaline crystal, altar, conjures, surge/dive
--    Player Manager — HP/prayer restore items, special threshold items
--    Loot          — checkboxes per drop, GP tracking toggle
--    Debug         — per-module debug flag toggles
--
--  USAGE:
--    local GuiModule = require("hermod/gui")
--    local gui = GuiModule.new(defaultConfig)
--
--    -- In your main loop draw the status overlay:
--    gui:drawStatus(state, stats)
--
--    -- The pre-start config window blocks until the user clicks "Start":
--    if not gui:isStarted() then
--      gui:drawConfig()
--      return
--    end
--
--    -- Read current config at any time:
--    local cfg = gui:getConfig()
-- =============================================================================

local API       = require("api")
local GLib      = require("core/gui_lib")   -- Sanson's ImGui helper

-- ---------------------------------------------------------------------------
-- Default configuration (matches the shape expected by main.lua)
-- ---------------------------------------------------------------------------
local DEFAULT_CONFIG = {
    -- General
    waitForFullHp        = true,
    hpThresholdPct       = 50,    -- eat food when HP % <= this
    hpCriticalPct        = 30,    -- emergency eat when HP % <= this
    hpSpecialPct         = 65,    -- use special restore (e.g. Excalibur) when HP % <= this
    prayerThresholdPct   = 20,    -- drink prayer restore when prayer % <= this
    prayerCriticalPct    = 10,    -- emergency prayer when prayer % <= this
    useCurses            = true,  -- true = Curses, false = Standard prayers

    -- War's Retreat
    useWarsRetreat       = true,  -- full banking loop via War's Retreat
    bankPin              = "",    -- bank PIN (string "1234")
    prayAtAltar          = true,  -- restore prayer/summon at Altar of War
    useAdrenCrystal      = true,  -- siphon from Adrenaline Crystal before portal
    summonConjures       = true,  -- resummon Ghost + Skeleton + Zombie before portal
    surgeDiveChance      = 50,    -- 0-100 % chance to Surge when navigating W.R.
    minHpToEnter         = 80,    -- don't enter portal if HP % < this
    minPrayerToEnter     = 50,    -- don't enter portal if prayer % < this

    -- Loot toggles (item IDs defined in main.lua LOOT_IDS)
    lootHermodicPlate    = true,
    lootArmourSpike      = true,
    lootBigBones         = false,
    lootCoins            = true,
    lootOtherDrops       = true,   -- catch-all for any other IDs in LOOT_IDS
    trackGp              = true,   -- estimate session GP from coin drops

    -- Debug
    debugMain            = false,
    debugTimer           = false,
    debugPlayer          = false,
    debugPrayer          = false,
    debugWars            = false,
}

-- ---------------------------------------------------------------------------
-- MODULE
-- ---------------------------------------------------------------------------
local GuiModule = {}
GuiModule.__index = GuiModule

function GuiModule.new(overrides)
    local self = setmetatable({}, GuiModule)

    -- Merge defaults with any caller-supplied overrides
    self._cfg     = {}
    for k, v in pairs(DEFAULT_CONFIG) do self._cfg[k] = v end
    if overrides then
        for k, v in pairs(overrides) do self._cfg[k] = v end
    end

    self._started     = false
    self._activeTab   = 1        -- which tab is open in the config window
    self._warningMsgs = {}       -- validation warning strings

    return self
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function GuiModule:isStarted()
    return self._started
end

function GuiModule:getConfig()
    return self._cfg
end

-- ---------------------------------------------------------------------------
-- Pre-start Configuration Window
-- Drawn every tick until the user presses "Start".
-- Returns true once the user has clicked Start.
-- ---------------------------------------------------------------------------
function GuiModule:drawConfig()
    local cfg = self._cfg

    -- ── Window frame ──────────────────────────────────────────────────────
    GLib.BeginWindow("Hermod, the Spirit of War", 480, 520)

    -- ── Title bar ─────────────────────────────────────────────────────────
    GLib.Title("⚔  Hermod, the Spirit of War", "sub", "Automated farming script")

    GLib.Separator()
    GLib.Spacing()

    -- ── Tab bar ───────────────────────────────────────────────────────────
    if GLib.BeginTabBar("ConfigTabs") then

        -- ── Tab 1: General ────────────────────────────────────────────────
        if GLib.Tab("General") then
            GLib.Spacing()
            GLib.SectionHeader("Combat Settings")

            cfg.waitForFullHp    = GLib.Checkbox("Wait for full HP before entering", cfg.waitForFullHp)
            cfg.useCurses        = GLib.Checkbox("Using Curses (Soul Split / Deflect Melee)", cfg.useCurses)

            GLib.Spacing()
            GLib.SectionHeader("Health Thresholds")

            cfg.hpThresholdPct  = GLib.SliderInt("Eat food at HP (%)",      cfg.hpThresholdPct,  10, 90)
            cfg.hpCriticalPct   = GLib.SliderInt("Emergency eat HP (%)",    cfg.hpCriticalPct,   5,  60)
            cfg.hpSpecialPct    = GLib.SliderInt("Special restore HP (%)",  cfg.hpSpecialPct,    20, 95)

            GLib.Spacing()
            GLib.SectionHeader("Prayer Thresholds")

            cfg.prayerThresholdPct = GLib.SliderInt("Drink restore at prayer (%)", cfg.prayerThresholdPct, 5,  60)
            cfg.prayerCriticalPct  = GLib.SliderInt("Emergency restore prayer (%)", cfg.prayerCriticalPct,  2,  40)

            GLib.EndTab()
        end

        -- ── Tab 2: War's Retreat ──────────────────────────────────────────
        if GLib.Tab("War's Retreat") then
            GLib.Spacing()

            cfg.useWarsRetreat = GLib.Checkbox("Enable full War's Retreat loop", cfg.useWarsRetreat)
            if not cfg.useWarsRetreat then
                GLib.TextColored("⚠ Without this, script expects you to be\n   already inside Hermod's instance.", 1, 0.8, 0.2, 1)
                GLib.EndTab()
            else
                GLib.Spacing()
                GLib.SectionHeader("Bank & Preparation")

                cfg.bankPin          = GLib.InputText("Bank PIN (leave blank if none)", cfg.bankPin)
                cfg.prayAtAltar      = GLib.Checkbox("Pray at Altar of War (restore prayer/summon)", cfg.prayAtAltar)
                cfg.useAdrenCrystal  = GLib.Checkbox("Use Adrenaline Crystal before portal", cfg.useAdrenCrystal)
                cfg.summonConjures   = GLib.Checkbox("Resummon conjures (Ghost + Skeleton + Zombie)", cfg.summonConjures)

                GLib.Spacing()
                GLib.SectionHeader("Navigation")

                cfg.surgeDiveChance  = GLib.SliderInt("Surge/Dive chance (%)", cfg.surgeDiveChance, 0, 100)

                GLib.Spacing()
                GLib.SectionHeader("Minimum Stats to Enter Portal")

                cfg.minHpToEnter      = GLib.SliderInt("Minimum HP (%)",     cfg.minHpToEnter,     30, 100)
                cfg.minPrayerToEnter  = GLib.SliderInt("Minimum Prayer (%)", cfg.minPrayerToEnter, 10, 100)

                GLib.Spacing()
                GLib.TextColored("ℹ Portal must be attuned to Hermod\n  in the War's Retreat portal menu.", 0.5, 0.8, 1, 1)

                GLib.EndTab()
            end
        end

        -- ── Tab 3: Player Manager ─────────────────────────────────────────
        if GLib.Tab("Player Manager") then
            GLib.Spacing()
            GLib.SectionHeader("Food & Restore Items")
            GLib.Text("Ensure these are in your inventory preset.")
            GLib.Spacing()
            GLib.Text("Food (normal):        Blue/Green Blubber Jellyfish")
            GLib.Text("Food (emergency):     Guthix Rest Flask")
            GLib.Text("Special restore:      Enhanced Excalibur (HP) / AERS (Prayer)")
            GLib.Text("Prayer restore:       Super Restore Flask / Saradomin Brew")
            GLib.Spacing()
            GLib.SectionHeader("Conjures (if enabled)")
            GLib.Text("Ghost Familiar, Skeleton Warrior,\nPutrid Zombie — summoned via ability bar.")
            GLib.Spacing()
            GLib.SectionHeader("Recommended Inventory")
            GLib.Text("• 1–2 Elder Overload Salve")
            GLib.Text("• 2–4 Adrenaline Renewal Flask")
            GLib.Text("• 1–2 Vulnerability Bomb")
            GLib.Text("• 1–2 Binding Contract (Ripper Demon)")
            GLib.Text("• 8–12 Blue Blubber Jellyfish")
            GLib.Text("• 2–3 Guthix Rest Flask (emergency)")
            GLib.Text("• 1 Super Restore Flask (prayer)")

            GLib.EndTab()
        end

        -- ── Tab 4: Loot ───────────────────────────────────────────────────
        if GLib.Tab("Loot") then
            GLib.Spacing()
            GLib.SectionHeader("Drops to Loot")

            cfg.lootHermodicPlate = GLib.Checkbox("Hermodic plate  (ID: 49394, ~1/10 drop)", cfg.lootHermodicPlate)
            cfg.lootArmourSpike   = GLib.Checkbox("Hermod's armour spike  (ID: ~49395, 1/2000)", cfg.lootArmourSpike)
            cfg.lootCoins         = GLib.Checkbox("Coins", cfg.lootCoins)
            cfg.lootBigBones      = GLib.Checkbox("Big bones", cfg.lootBigBones)
            cfg.lootOtherDrops    = GLib.Checkbox("Other items in LOOT_IDS list", cfg.lootOtherDrops)

            GLib.Spacing()
            GLib.SectionHeader("Statistics")

            cfg.trackGp = GLib.Checkbox("Track estimated GP per session (from coins)", cfg.trackGp)

            GLib.Spacing()
            GLib.TextColored("ℹ Verify item IDs in-game using\n  MemoryError's Ground Item overlay.", 0.5, 0.8, 1, 1)

            GLib.EndTab()
        end

        -- ── Tab 5: Debug ──────────────────────────────────────────────────
        if GLib.Tab("Debug") then
            GLib.Spacing()
            GLib.SectionHeader("Enable Debug Logging")
            GLib.Text("Logs appear in the MemoryError console.")
            GLib.Spacing()

            cfg.debugMain   = GLib.Checkbox("Main script flow",         cfg.debugMain)
            cfg.debugTimer  = GLib.Checkbox("Timer / task execution",   cfg.debugTimer)
            cfg.debugPlayer = GLib.Checkbox("Player Manager",           cfg.debugPlayer)
            cfg.debugPrayer = GLib.Checkbox("Prayer Flicker",           cfg.debugPrayer)
            cfg.debugWars   = GLib.Checkbox("War's Retreat navigation", cfg.debugWars)

            GLib.EndTab()
        end

        GLib.EndTabBar()
    end

    -- ── Warnings ──────────────────────────────────────────────────────────
    self:_validateConfig()
    if #self._warningMsgs > 0 then
        GLib.Spacing()
        GLib.Separator()
        GLib.Spacing()
        for _, msg in ipairs(self._warningMsgs) do
            GLib.TextColored("⚠ " .. msg, 1, 0.5, 0.2, 1)
        end
        GLib.Spacing()
    end

    -- ── Start / Cancel buttons ────────────────────────────────────────────
    GLib.Spacing()
    GLib.Separator()
    GLib.Spacing()

    if GLib.Button("▶  Start", 180, 36) then
        self._started = true
    end

    GLib.SameLine()

    if GLib.Button("✕  Cancel", 100, 36) then
        API.Write_LoopyLoop(false)   -- stop the script
    end

    GLib.EndWindow()
end

-- ---------------------------------------------------------------------------
-- Live Status Overlay (drawn every tick while script is running)
-- ---------------------------------------------------------------------------
--  stats = {
--    state         = string,
--    killCount     = number,
--    sessionSecs   = number,
--    estimatedGP   = number,
--    hp            = number (percent),
--    prayer        = number (percent),
--    hermodAlive   = bool,
--    phantomCount  = number,
--    lastTarget    = string,
--    atWars        = bool,
--  }
-- ---------------------------------------------------------------------------
function GuiModule:drawStatus(stats)
    local s = stats or {}

    -- Runtime formatting
    local t    = s.sessionSecs or 0
    local hrs  = math.floor(t / 3600)
    local mins = math.floor((t % 3600) / 60)
    local secs = t % 60
    local rt   = string.format("%02d:%02d:%02d", hrs, mins, secs)

    -- Kills/hr
    local kph = (t > 0) and string.format("%.1f", (s.killCount or 0) / (t / 3600)) or "—"

    -- GP estimate
    local gpStr = self._cfg.trackGp and string.format("%s gp", commify(s.estimatedGP or 0)) or "N/A"

    API.DrawTable({
        { "⚔  Hermod, Spirit of War", "" },
        { "State",         s.state or "—" },
        { "─────────────", "─────────────" },
        { "Kills",         tostring(s.killCount or 0) .. "  (" .. kph .. "/hr)" },
        { "Runtime",       rt },
        { "Est. GP",       gpStr },
        { "─────────────", "─────────────" },
        { "HP",            string.format("%d%%", s.hp or 0) },
        { "Prayer",        string.format("%d%%", s.prayer or 0) },
        { "─────────────", "─────────────" },
        { "Hermod",        (s.hermodAlive and "Alive" or "Dead / Absent") },
        { "Phantoms",      tostring(s.phantomCount or 0) },
        { "Last target",   s.lastTarget or "—" },
        { "At War's",      tostring(s.atWars or false) },
    })
end

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------

function GuiModule:_validateConfig()
    self._warningMsgs = {}
    local cfg = self._cfg

    if cfg.hpCriticalPct >= cfg.hpThresholdPct then
        table.insert(self._warningMsgs, "Emergency HP threshold should be lower than normal threshold")
    end
    if cfg.prayerCriticalPct >= cfg.prayerThresholdPct then
        table.insert(self._warningMsgs, "Emergency prayer threshold should be lower than normal threshold")
    end
    if cfg.useWarsRetreat and cfg.minHpToEnter < cfg.hpThresholdPct then
        table.insert(self._warningMsgs, "Min HP to enter portal is lower than your eat threshold — you may eat mid-run")
    end
    if cfg.useAdrenCrystal then
        table.insert(self._warningMsgs, "Adrenaline Crystal requires 1,000 boss kills to unlock")
    end
    if cfg.summonConjures then
        table.insert(self._warningMsgs, "Conjure abilities must be on your action bar for auto-summon to work")
    end
end

-- Comma-format large numbers  e.g. 1234567 → "1,234,567"
function commify(n)
    local s = tostring(math.floor(n or 0))
    local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return result:gsub("^,", "")
end

return GuiModule
