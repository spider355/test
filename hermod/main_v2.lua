-- =============================================================================
--  HERMOD, THE SPIRIT OF WAR — Boss Script  [v2.0]
--  MemoryError RS3 Client | Lua
--  Modelled on Sonson's Rasial architecture
--
--  FILE STRUCTURE (put both files in Lua_Scripts\hermod\):
--    Lua_Scripts\
--    ├── core\
--    │   ├── timer.lua
--    │   ├── player_manager.lua
--    │   ├── prayer_flicker.lua
--    │   ├── wars_retreat.lua
--    │   └── gui_lib.lua
--    ├── hermod\
--    │   ├── main.lua     ← this file
--    │   └── gui.lua
--    ├── api.lua
--    └── usertypes.lua
--
--  In MemoryError Script Manager: run "hermod/main"
-- =============================================================================

-- ── MEMORYERROR API IMPORTS ──────────────────────────────────────────────────
local API       = require("api")
local usertypes = require("usertypes")

-- ── LIBRARY IMPORTS ──────────────────────────────────────────────────────────
local Timer         = require("core/timer")
local PlayerManager = require("core/player_manager")
local PrayerFlicker = require("core/prayer_flicker")
local WarsRetreat   = require("core/wars_retreat")
local GuiModule     = require("hermod/gui")

-- ── CONSTANTS — VERIFY THESE IN-GAME BEFORE FIRST RUN ───────────────────────
local NPC_ID = {
    HERMOD           = 30163,  -- Hermod, the Spirit of War
    ARMOURED_PHANTOM = 30164,  -- Armoured phantom
}

-- Ground item IDs — confirm with MemoryError's Ground Items overlay in-game.
-- Each entry has: id, human name, config key (from GUI toggles), gp estimate.
local ALL_LOOT = {
    { id = 49394, name = "Hermodic plate",        key = "lootHermodicPlate", gpValue = 500000 },
    { id = 49395, name = "Hermod's armour spike", key = "lootArmourSpike",   gpValue = 200000 },
    { id = 536,   name = "Big bones",             key = "lootBigBones",      gpValue = 300    },
    { id = 995,   name = "Coins",                 key = "lootCoins",         gpValue = 1      },
    -- Add more rows here as you discover drops, use key = "lootOtherDrops" for extras
}

-- Boss room tile — stand inside and read your coords from MemoryError overlay,
-- then update x and y here.
local BOSS_ROOM_COORDS = { x = 864, y = 1760, range = 35 }

-- Timing tuning
local LOOP_SLEEP_MS   = 150
local LOOP_SLEEP_VAR  = 50
local LOOT_WINDOW_SEC = 12   -- seconds spent looting after each kill
local RETURN_DELAY_MS = 2000 -- brief wait before teleporting back to War's Retreat

-- ── STATE MACHINE ────────────────────────────────────────────────────────────
-- Full loop (Wars Retreat enabled):
--   IDLE → WARS_RETREAT → ENTERING → FIGHTING → KILLING_MINIONS → LOOTING → RETURNING → WARS_RETREAT ...
-- Manual loop (Wars Retreat disabled):
--   IDLE → ENTERING → FIGHTING → KILLING_MINIONS → LOOTING → ENTERING ...
local States = {
    IDLE              = "IDLE",
    WARS_RETREAT      = "WAR'S RETREAT",
    ENTERING_INSTANCE = "ENTERING",
    FIGHTING_BOSS     = "FIGHTING BOSS",
    KILLING_MINIONS   = "KILLING MINIONS",
    LOOTING           = "LOOTING",
    RETURNING         = "RETURNING",
}

-- ── RUNTIME VARIABLES ────────────────────────────────────────────────────────
local currentState  = States.IDLE
local lootStartTime = 0
local returnStartT  = 0
local killCount     = 0
local sessionStart  = os.time()
local estimatedGP   = 0
local lastTargetId  = 0
local CFG           = nil   -- set after GUI Start is clicked

-- ── LOGGING ──────────────────────────────────────────────────────────────────
-- MemoryError uses print() for its Lua console output.
-- Debug-module flags are read from CFG once the GUI has been confirmed.
local function log(msg, module)
    -- Filter by per-module debug flags once config is loaded
    if CFG then
        if module == "timer"  and not CFG.debugTimer  then return end
        if module == "player" and not CFG.debugPlayer then return end
        if module == "prayer" and not CFG.debugPrayer then return end
        if module == "wars"   and not CFG.debugWars   then return end
        if module == "debug"  and not CFG.debugMain   then return end
    end
    print(tostring(msg))
end

local function logMain(msg)  log(msg)          end  -- always shown
local function logDebug(msg) log(msg, "debug") end  -- only when debugMain = true

-- ── SMALL UTILITIES ──────────────────────────────────────────────────────────
local function commify(n)
    local s = tostring(math.floor(n or 0))
    local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return r:gsub("^,", "")
end

local function getNPCs(id, range)
    return API.GetAllObjArrayInteract({id}, 1, range or 30) or {}
end

local function hermodExists()   return #getNPCs(NPC_ID.HERMOD,           30) > 0 end
local function getPhantoms()    return getNPCs(NPC_ID.ARMOURED_PHANTOM,  30)     end
local function phantomsAlive()  return #getPhantoms() > 0                        end
local function phantomCount()   return #getPhantoms()                            end

local function attackNPC(id, range)
    return API.DoAction_NPC1(0x10, API.OFF_ACT_NpcT_route, {id}, range or 30)
end

local function buildLootIds()
    local ids = {}
    for _, entry in ipairs(ALL_LOOT) do
        -- If CFG not yet loaded loot everything; otherwise respect toggle
        local enabled = not CFG
            or CFG[entry.key]
            or (not CFG[entry.key] and entry.key == "lootOtherDrops" and CFG.lootOtherDrops)
        if enabled then
            table.insert(ids, entry.id)
        end
    end
    return ids
end

local function lootNearbyItems()
    for _, itemId in ipairs(buildLootIds()) do
        local ground = API.GetAllObjArrayInteract({itemId}, 4, 8)
        if ground and #ground > 0 then
            logMain(string.format("[Loot] Picking up item %d", itemId))
            API.DoAction_Object1(0x5, API.OFF_ACT_GeneralObject_route0, {itemId}, 8)
            API.RandomSleep2(400, 80, 80)
            if CFG and CFG.trackGp then
                for _, entry in ipairs(ALL_LOOT) do
                    if entry.id == itemId then
                        estimatedGP = estimatedGP + (entry.gpValue or 0)
                    end
                end
            end
        end
    end
end

-- ── GUI — CONFIG WINDOW ───────────────────────────────────────────────────────
local gui = GuiModule.new()

logMain("[Hermod] Waiting for config GUI...")
while API.Read_LoopyLoop() and not gui:isStarted() do
    gui:drawConfig()
    API.RandomSleep2(50, 10, 10)
end

if not API.Read_LoopyLoop() then
    logMain("[Hermod] Cancelled before start.")
    return
end

CFG = gui:getConfig()
logMain(string.format("[Hermod] Starting | Mode: %s | Curses: %s | Adrenaline crystal: %s",
    CFG.useWarsRetreat and "Wars Retreat loop" or "Manual",
    tostring(CFG.useCurses),
    tostring(CFG.useAdrenCrystal)))

-- ── WAR'S RETREAT MODULE ──────────────────────────────────────────────────────
local warsRetreat = nil
if CFG.useWarsRetreat then
    local ok, WR = pcall(require, "core/wars_retreat")
    if ok then
        warsRetreat = WR.new({
            bankPin         = CFG.bankPin,
            summonConjures  = CFG.summonConjures,
            useAdrenCrystal = CFG.useAdrenCrystal,
            prayAtAltar     = CFG.prayAtAltar,
            surgeDiveChance = CFG.surgeDiveChance,
            minHealth       = CFG.minHpToEnter,
            minPrayer       = CFG.minPrayerToEnter,
            bossPortalName  = "Hermod, the Spirit of War",
            debugMode       = CFG.debugWars,
        })
        logMain("[Hermod] War's Retreat module loaded.")
    else
        logMain("[Hermod] WARNING: core/wars_retreat.lua not found — disabling War's Retreat loop.")
        CFG.useWarsRetreat = false
    end
end

-- ── PRAYER FLICKER ────────────────────────────────────────────────────────────
local SOUL_SPLIT    = CFG.useCurses and PrayerFlicker.CURSES.SOUL_SPLIT    or PrayerFlicker.PRAYERS.RAPID_HEAL
local DEFLECT_MELEE = CFG.useCurses and PrayerFlicker.CURSES.DEFLECT_MELEE or PrayerFlicker.PRAYERS.PROTECT_FROM_MELEE

local prayerFlicker = PrayerFlicker.new({
    defaultPrayer = SOUL_SPLIT,
    threats = {
        {
            name      = "Armoured Phantom melee",
            type      = "Conditional",
            priority  = 10,
            prayer    = DEFLECT_MELEE,
            condition = function() return phantomsAlive() end,
            duration  = 2,
            delay     = 0,
        },
    },
    debugMode = CFG.debugPrayer,
})

-- ── PLAYER MANAGER ────────────────────────────────────────────────────────────
local playerManager = PlayerManager.new({
    health = {
        normal   = { type = "percent", value = CFG.hpThresholdPct },
        critical = { type = "percent", value = CFG.hpCriticalPct  },
        special  = { type = "percent", value = CFG.hpSpecialPct   },
    },
    prayer = {
        normal   = { type = "percent", value = CFG.prayerThresholdPct },
        critical = { type = "percent", value = CFG.prayerCriticalPct  },
    },
    locations = {
        { name = "Hermod's Arena", coords = BOSS_ROOM_COORDS },
    },
    debugMode = CFG.debugPlayer,
})

-- ── TIMERS ────────────────────────────────────────────────────────────────────
local attackBossTimer = Timer.new({
    name     = "Attack Hermod",
    cooldown = 3,
    useTicks = true,
    condition = function()
        return currentState == States.FIGHTING_BOSS
            and hermodExists()
            and not phantomsAlive()
            and not API.PlayerIsMovin2()
    end,
    action = function()
        if lastTargetId ~= NPC_ID.HERMOD then
            logDebug("[Timer] Re-targeting Hermod after phantom phase")
            lastTargetId = NPC_ID.HERMOD
        end
        return attackNPC(NPC_ID.HERMOD)
    end,
    debugMode = CFG.debugTimer,
})

local attackPhantomTimer = Timer.new({
    name     = "Attack Phantoms",
    cooldown = 2,
    useTicks = true,
    condition = function()
        return currentState == States.KILLING_MINIONS
            and phantomsAlive()
            and not API.PlayerIsMovin2()
    end,
    action = function()
        local ph = getPhantoms()
        if #ph > 0 then
            if lastTargetId ~= NPC_ID.ARMOURED_PHANTOM then
                logDebug(string.format("[Timer] Targeting Phantom (%d alive)", #ph))
                lastTargetId = NPC_ID.ARMOURED_PHANTOM
            end
            return attackNPC(NPC_ID.ARMOURED_PHANTOM)
        end
        return false
    end,
    debugMode = CFG.debugTimer,
})

local lootTimer = Timer.new({
    name     = "Loot",
    cooldown = 700,
    useTicks = false,
    condition = function() return currentState == States.LOOTING end,
    action    = function() lootNearbyItems(); return true end,
    debugMode = CFG.debugTimer,
})

-- ── STATE MACHINE TICK ────────────────────────────────────────────────────────
local function updateState()
    local hp             = (API.GetHP and API.GetHP()) or 100
    local hermodPresent  = hermodExists()
    local minionsPresent = phantomsAlive()

    -- IDLE ────────────────────────────────────────────────────────────────────
    if currentState == States.IDLE then
        if CFG.useWarsRetreat then
            logMain("[State] → WARS_RETREAT")
            currentState = States.WARS_RETREAT
        else
            logMain("[State] → ENTERING (manual mode, waiting in instance)")
            currentState = States.ENTERING_INSTANCE
        end
        return
    end

    -- WARS_RETREAT ────────────────────────────────────────────────────────────
    if currentState == States.WARS_RETREAT then
        if not warsRetreat then
            currentState = States.ENTERING_INSTANCE
            return
        end
        if warsRetreat:run() then
            logMain("[State] Prep done → ENTERING_INSTANCE")
            currentState = States.ENTERING_INSTANCE
        end
        return
    end

    -- ENTERING_INSTANCE ───────────────────────────────────────────────────────
    if currentState == States.ENTERING_INSTANCE then
        if CFG.waitForFullHp and hp < 95 then return end
        if hermodPresent then
            logMain("[State] Hermod detected → FIGHTING_BOSS")
            lastTargetId = NPC_ID.HERMOD
            currentState = States.FIGHTING_BOSS
        end
        return
    end

    -- FIGHTING_BOSS ───────────────────────────────────────────────────────────
    if currentState == States.FIGHTING_BOSS then
        if not hermodPresent then
            killCount     = killCount + 1
            lootStartTime = os.time()
            logMain(string.format("[State] Kill #%d → LOOTING", killCount))
            currentState = States.LOOTING
            return
        end
        if minionsPresent then
            logMain(string.format("[State] %d phantoms spawned → KILLING_MINIONS", phantomCount()))
            lastTargetId = NPC_ID.ARMOURED_PHANTOM
            currentState = States.KILLING_MINIONS
        end
        return
    end

    -- KILLING_MINIONS ─────────────────────────────────────────────────────────
    if currentState == States.KILLING_MINIONS then
        if not minionsPresent then
            if hermodPresent then
                logMain("[State] Phantoms dead → FIGHTING_BOSS")
                lastTargetId = NPC_ID.HERMOD
                currentState = States.FIGHTING_BOSS
            else
                killCount     = killCount + 1
                lootStartTime = os.time()
                logMain(string.format("[State] Phantoms dead + Hermod gone → LOOTING (kill #%d)", killCount))
                currentState = States.LOOTING
            end
        end
        return
    end

    -- LOOTING ─────────────────────────────────────────────────────────────────
    if currentState == States.LOOTING then
        if os.time() - lootStartTime >= LOOT_WINDOW_SEC then
            lootStartTime = 0
            if CFG.useWarsRetreat then
                returnStartT = os.clock() * 1000
                logMain("[State] Loot done → RETURNING")
                currentState = States.RETURNING
            else
                logMain("[State] Loot done → ENTERING_INSTANCE (waiting for respawn)")
                currentState = States.ENTERING_INSTANCE
            end
        end
        return
    end

    -- RETURNING ───────────────────────────────────────────────────────────────
    if currentState == States.RETURNING then
        local elapsed = (os.clock() * 1000) - returnStartT
        if elapsed >= RETURN_DELAY_MS then
            logMain("[State] Teleporting to War's Retreat...")
            -- War's Retreat Teleport — interface 1465 component 17 is the standard
            -- location. Verify with MemoryError's interface inspector if it fails.
            API.DoAction_Interface(0xffffffff, 0xffffffff, 0, 1465, 17, -1,
                API.OFF_ACT_GeneralInterface_route)
            API.RandomSleep2(2500, 300, 300)
            currentState = States.WARS_RETREAT
        end
        return
    end
end

-- ── STATS FOR OVERLAY ─────────────────────────────────────────────────────────
local function buildStats()
    return {
        state        = currentState,
        killCount    = killCount,
        sessionSecs  = os.time() - sessionStart,
        estimatedGP  = estimatedGP,
        hp           = (API.GetHP and API.GetHP()) or 0,
        prayer       = (API.GetPrayPrecent and API.GetPrayPrecent()) or 0,
        hermodAlive  = hermodExists(),
        phantomCount = phantomCount(),
        lastTarget   = (lastTargetId == NPC_ID.HERMOD          and "Hermod")
                    or (lastTargetId == NPC_ID.ARMOURED_PHANTOM and "Phantom")
                    or "—",
        atWars       = (currentState == States.WARS_RETREAT),
    }
end

-- ── MAIN LOOP ─────────────────────────────────────────────────────────────────
logMain("[Hermod] Main loop starting...")
currentState = States.IDLE

while API.Read_LoopyLoop() do

    -- 1. Always manage HP and prayer
    playerManager:update()
    playerManager:manageHealth()
    playerManager:managePrayer()

    -- 2. Prayer flicker — only active in combat states
    if currentState == States.FIGHTING_BOSS or currentState == States.KILLING_MINIONS then
        prayerFlicker:update()
    else
        prayerFlicker:deactivatePrayer()
    end

    -- 3. State machine
    updateState()

    -- 4. Execute timed combat / loot actions
    if     currentState == States.FIGHTING_BOSS   then attackBossTimer:execute()
    elseif currentState == States.KILLING_MINIONS then attackPhantomTimer:execute()
    elseif currentState == States.LOOTING         then lootTimer:execute()
    end

    -- 5. Status overlay
    gui:drawStatus(buildStats())

    -- 6. Loop sleep
    API.RandomSleep2(LOOP_SLEEP_MS, LOOP_SLEEP_VAR, LOOP_SLEEP_VAR)
end

-- ── CLEANUP ───────────────────────────────────────────────────────────────────
prayerFlicker:deactivatePrayer()
logMain(string.format("[Hermod] Stopped. Kills: %d | GP: ~%s | Runtime: %ds",
    killCount, commify(estimatedGP), os.time() - sessionStart))
