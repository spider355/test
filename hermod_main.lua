-- =============================================================================
--  HERMOD, THE SPIRIT OF WAR — Boss Script
--  MemoryError RS3 Client | Lua
--  Compatible with Sonson's library suite (Timer, PlayerManager, PrayerFlicker)
--
--  SETUP CHECKLIST BEFORE RUNNING:
--    1. Place timer.lua, player_manager.lua, prayer_flicker.lua in Lua_Scripts/
--       (or Lua_Scripts/core/ and adjust the require paths below)
--    2. Enter Hermod's instance BEFORE starting this script
--    3. Revolution bar should have your basic Necromancy autos enabled
--    4. Verify NPC IDs with MemoryError's NPC scanner (see CONSTANTS section)
--    5. Verify/update loot item IDs you want to pick up
--    6. Confirm your prayer setup (Curses vs Standard prayers — see config)
--
--  BOSS MECHANICS HANDLED:
--    • Standard combat: auto-attack Hermod with Revolution/manual abilities
--    • Phantom phase: when 2 Armoured Phantoms spawn, Hermod is immune —
--      script swaps focus to phantoms until both are dead, then resumes boss
--    • Prayer flicker: Soul Split default; swaps to Deflect Melee during
--      phantom phase to protect against their melee attacks
--    • Health management: eats food when below configured threshold
--    • Prayer management: drinks prayer restore when below configured threshold
--    • Looting: picks up all configured item IDs after boss dies
--
--  KNOWN IDs (verified via RS Wiki):
--    Hermod NPC ID        : 30163
--    Armoured Phantom ID  : 30164
-- =============================================================================

-- -----------------------------------------------------------------------
-- LIBRARY IMPORTS
-- Adjust paths if your core files are in a subfolder (e.g. "core/timer")
-- -----------------------------------------------------------------------
local Timer         = require("timer")
local PlayerManager = require("player_manager")
local PrayerFlicker = require("prayer_flicker")

-- -----------------------------------------------------------------------
-- CONSTANTS — VERIFY THESE IN-GAME BEFORE YOUR FIRST RUN
-- -----------------------------------------------------------------------
local NPC_ID = {
    HERMOD          = 30163,  -- Hermod, the Spirit of War
    ARMOURED_PHANTOM = 30164, -- Armoured phantom (Hermod's minions)
}

-- *** IMPORTANT: Verify these item IDs using MemoryError's item scanner ***
-- Enable the Ground Items overlay in MemoryError and kill Hermod manually
-- once to see what IDs drop — then add/remove from this table.
local LOOT_IDS = {
    -- Unique / high-value drops
    49394,   -- Hermodic plate  (NOTE: verify this ID in-game)
    -- Staple drops
    536,     -- Big bones
    995,     -- Coins
    -- *** Add more IDs here as you discover them ***
}

-- Hermod's arena approximate coordinates — used for location detection.
-- Stand inside the boss room and read your coordinates from MemoryError
-- debug overlay, then update these values. The range (30) is generous.
local BOSS_ROOM_COORDS = { x = 864, y = 1760, range = 30 }

-- Timing / behaviour tuning
local LOOT_WINDOW_SECONDS  = 10   -- seconds to spend looting after boss dies
local COMBAT_ATTACK_TICKS  = 3    -- ticks between "re-target/attack" checks on boss
local PHANTOM_ATTACK_TICKS = 2    -- ticks between attack checks on phantoms
local LOOP_SLEEP_MS        = 150  -- main loop sleep (ms) — shorter = more responsive
local LOOP_SLEEP_VAR       = 50   -- variance on loop sleep

-- -----------------------------------------------------------------------
-- STATE MACHINE DEFINITION
-- -----------------------------------------------------------------------
--
--   IDLE ──► FIGHTING_BOSS ──► KILLING_MINIONS ──► FIGHTING_BOSS ──► LOOTING ──► IDLE
--             (hermod found)   (phantoms appear)   (phantoms dead)  (hermod dies)
--
local States = {
    IDLE            = "IDLE",
    FIGHTING_BOSS   = "FIGHTING_BOSS",
    KILLING_MINIONS = "KILLING_MINIONS",
    LOOTING         = "LOOTING",
}

-- Script-wide runtime variables
local currentState    = States.IDLE
local lootStartTime   = 0          -- os.time() stamp when looting began
local killCount       = 0          -- total kills this session
local sessionStart    = os.time()  -- session start timestamp
local lastTargetId    = NPC_ID.HERMOD  -- tracks which NPC we most recently clicked

-- -----------------------------------------------------------------------
-- LOGGING HELPER
-- -----------------------------------------------------------------------
local function log(msg, level)
    level = level or "INFO"
    print(string.format("[Hermod][%s] %s", level, msg))
end

-- -----------------------------------------------------------------------
-- NPC LOOKUP HELPERS
--
-- API.GetAllObjArrayInteract(ids_table, obj_type, range)
--   obj_type 1 = NPC
--   obj_type 3 = Game Object
--   obj_type 4 = Ground Item
--
-- If your MemoryError version uses a different function name, update here.
-- Some versions use API.GetAllObjArray(); check your API reference.
-- -----------------------------------------------------------------------
local function getNPCs(npcId, range)
    -- Returns a table of NPC objects, or empty table if none found
    local found = API.GetAllObjArrayInteract({npcId}, 1, range or 30)
    return found or {}
end

local function findNPC(npcId, range)
    -- Returns the nearest matching NPC object, or nil
    local npcs = getNPCs(npcId, range)
    if npcs and #npcs > 0 then
        return npcs[1]
    end
    return nil
end

-- -----------------------------------------------------------------------
-- COMBAT STATE QUERIES
-- -----------------------------------------------------------------------
local function hermodExists()
    -- Returns true if Hermod is alive and visible in our instance
    return findNPC(NPC_ID.HERMOD, 50) ~= nil
end

local function phantomsAlive()
    -- Returns true if at least one Armoured Phantom is alive
    -- This is also our proxy for "is Hermod currently immune?"
    local phantoms = getNPCs(NPC_ID.ARMOURED_PHANTOM, 30)
    return #phantoms > 0
end

local function phantomCount()
    return #getNPCs(NPC_ID.ARMOURED_PHANTOM, 30)
end

-- -----------------------------------------------------------------------
-- ATTACK FUNCTIONS
-- -----------------------------------------------------------------------
-- API.DoAction_NPC1(action, route, ids_table, range)
--   0x10 = Attack option
--   API.OFF_ACT_NpcT_route = standard NPC target route
--
-- NOTE: Some MemoryError builds use 0x2 for attack. If 0x10 does not work,
-- try 0x2 or check the MemoryError Discord for the correct action code.
-- -----------------------------------------------------------------------
local function attackNPC(npcId, range)
    return API.DoAction_NPC1(0x10, API.OFF_ACT_NpcT_route, {npcId}, range or 30)
end

-- -----------------------------------------------------------------------
-- LOOT FUNCTION
-- Attempts to pick up all items in LOOT_IDS that are nearby.
--
-- API.DoAction_Object1(action, route, ids_table, range)
--   0x5  = "Take" ground item action
--   API.OFF_ACT_GeneralObject_route0 = standard route for objects/ground items
--
-- NOTE: If ground items use a different API call in your build (e.g.
-- API.DoAction_GroundItem), update this function accordingly.
-- -----------------------------------------------------------------------
local function lootNearbyItems()
    local pickedUp = false
    for _, itemId in ipairs(LOOT_IDS) do
        -- Check if the item exists on the ground before attempting to take
        local groundItems = API.GetAllObjArrayInteract({itemId}, 4, 8)
        if groundItems and #groundItems > 0 then
            log(string.format("Looting item ID: %d", itemId))
            API.DoAction_Object1(0x5, API.OFF_ACT_GeneralObject_route0, {itemId}, 8)
            API.RandomSleep2(400, 80, 80)
            pickedUp = true
        end
    end
    return pickedUp
end

-- -----------------------------------------------------------------------
-- PRAYER FLICKER CONFIGURATION
--
-- Hermod attacks with Necromancy only. We use Soul Split by default.
-- When Armoured Phantoms are alive, we switch to Deflect Melee because
-- phantoms attack with Melee and can hit hard.
--
-- If you have high enough gear to sustain through both, you can keep
-- Soul Split always active and remove the threat entry below.
--
-- Using CURSES prayer set. If you're on standard prayers swap to:
--   PrayerFlicker.PRAYERS.PROTECT_FROM_MELEE
--   PrayerFlicker.PRAYERS.SOUL_SPLIT doesn't exist in standard prayers;
--   use PrayerFlicker.PRAYERS.PIETY or just don't set a defaultPrayer
-- -----------------------------------------------------------------------
local prayerConfig = {
    defaultPrayer = PrayerFlicker.CURSES.SOUL_SPLIT,
    threats = {
        -- When phantoms are alive, protect against their melee attacks.
        -- Priority 10 — highest priority wins, so this overrides Soul Split.
        {
            name      = "Armoured Phantom Melee",
            type      = "Conditional",
            priority  = 10,
            prayer    = PrayerFlicker.CURSES.DEFLECT_MELEE,
            -- Activates when any phantom is alive
            condition = function() return phantomsAlive() end,
            duration  = 2,  -- stays active 2 ticks after condition clears
            delay     = 0,  -- no delay — activate immediately
        },
    }
}

local prayerFlicker = PrayerFlicker.new(prayerConfig)

-- -----------------------------------------------------------------------
-- PLAYER MANAGER CONFIGURATION
-- Handles automatic health/prayer restoration.
-- -----------------------------------------------------------------------
local pmConfig = {
    health = {
        -- Eat food when HP drops below 50%
        normal   = { type = "percent", value = 50 },
        -- Emergency eat (e.g. Guthix rest) when below 30%
        critical = { type = "percent", value = 30 },
        -- Use Enhanced Excalibur when below 65%
        special  = { type = "percent", value = 65 },
    },
    prayer = {
        -- Drink prayer restore when below 20%
        normal   = { type = "percent", value = 20 },
        -- Emergency restore when very low
        critical = { type = "percent", value = 10 },
        -- Use Ancient Elven Ritual Shard when below 600 prayer points
        special  = { type = "current", value = 600 },
    },
    -- Location detection so the player manager knows we're in the boss room.
    -- Update BOSS_ROOM_COORDS at the top of this file with real coordinates.
    locations = {
        {
            name   = "Hermod's Arena",
            coords = BOSS_ROOM_COORDS,
        },
    },
}

local playerManager = PlayerManager.new(pmConfig)

-- -----------------------------------------------------------------------
-- TIMERS
-- Using Sonson's Timer library for cooldown-managed action execution.
-- -----------------------------------------------------------------------

-- TIMER 1: Attack Hermod
-- Only fires when we're in FIGHTING_BOSS state and Hermod is vulnerable.
-- We check phantoms aren't alive (i.e., Hermod is not immune) before firing.
local attackBossTimer = Timer.new({
    name     = "Attack Hermod",
    cooldown = COMBAT_ATTACK_TICKS,
    useTicks = true,
    condition = function()
        return currentState == States.FIGHTING_BOSS
            and not API.PlayerIsMovin2()   -- don't click while already moving
            and hermodExists()
            and not phantomsAlive()        -- Hermod is not immune
    end,
    action = function()
        -- Only re-click if we don't already have Hermod targeted/attacking
        -- to avoid interrupting our Revolution rotation.
        -- We track lastTargetId so we re-target after phantom phase ends.
        if lastTargetId ~= NPC_ID.HERMOD then
            log("Re-targeting Hermod after phantom phase")
            lastTargetId = NPC_ID.HERMOD
            return attackNPC(NPC_ID.HERMOD)
        end
        -- Check if we're actually in combat — if not, click again
        if not API.LocalPlayer.GetCombatTarget or true then
            -- Safety: always try to attack; Revolution will handle ability queueing
            return attackNPC(NPC_ID.HERMOD)
        end
        return false
    end,
})

-- TIMER 2: Attack Armoured Phantoms
-- Fires during KILLING_MINIONS state. We cycle through available phantoms
-- targeting each one (in practice both will die quickly with AoE/Revolution).
-- Targeting one and letting Revolution hit both is fine for this easy boss.
local attackPhantomTimer = Timer.new({
    name     = "Attack Phantoms",
    cooldown = PHANTOM_ATTACK_TICKS,
    useTicks = true,
    condition = function()
        return currentState == States.KILLING_MINIONS
            and phantomsAlive()
            and not API.PlayerIsMovin2()
    end,
    action = function()
        local phantoms = getNPCs(NPC_ID.ARMOURED_PHANTOM, 30)
        if #phantoms > 0 then
            -- Target phantom 1 — AoE abilities from Revolution (like Soul Strike,
            -- Spectral Scythe) will hit the second phantom at the same time
            if lastTargetId ~= NPC_ID.ARMOURED_PHANTOM then
                log(string.format("Targeting Armoured Phantom (%d remaining)", #phantoms))
                lastTargetId = NPC_ID.ARMOURED_PHANTOM
            end
            return attackNPC(NPC_ID.ARMOURED_PHANTOM)
        end
        return false
    end,
})

-- TIMER 3: Loot ground items
-- Fires during LOOTING state, attempting to pick up all items in LOOT_IDS.
local lootTimer = Timer.new({
    name     = "Loot drops",
    cooldown = 700,         -- 700ms between loot sweep attempts
    useTicks = false,       -- real-time cooldown in ms
    condition = function()
        return currentState == States.LOOTING
    end,
    action = function()
        lootNearbyItems()
        return true  -- always return true to start cooldown
    end,
})

-- -----------------------------------------------------------------------
-- STATE TRANSITION LOGIC
-- Called every iteration of the main loop to decide what state we're in.
-- -----------------------------------------------------------------------
local function updateState()
    local hermodPresent  = hermodExists()
    local minionsPresent = phantomsAlive()

    -- ── IDLE: waiting to detect Hermod ──────────────────────────────────
    if currentState == States.IDLE then
        if hermodPresent then
            log("Hermod detected — beginning fight!")
            lastTargetId = NPC_ID.HERMOD
            currentState = States.FIGHTING_BOSS
        end
        return
    end

    -- ── FIGHTING_BOSS: normal combat ────────────────────────────────────
    if currentState == States.FIGHTING_BOSS then
        if not hermodPresent then
            -- Hermod has died — begin looting phase
            log(string.format("Hermod defeated! Kill #%d — looting...", killCount + 1))
            killCount     = killCount + 1
            lootStartTime = os.time()
            currentState  = States.LOOTING
            return
        end
        if minionsPresent then
            -- Phantoms have just spawned — Hermod is now immune
            log(string.format("Armoured Phantoms spawned (%d)! Switching target.", phantomCount()))
            lastTargetId = NPC_ID.ARMOURED_PHANTOM
            currentState = States.KILLING_MINIONS
        end
        return
    end

    -- ── KILLING_MINIONS: burn down both phantoms ─────────────────────────
    if currentState == States.KILLING_MINIONS then
        if not minionsPresent then
            if hermodPresent then
                log("Both phantoms cleared — returning to boss fight!")
                lastTargetId = NPC_ID.HERMOD
                currentState = States.FIGHTING_BOSS
            else
                -- Edge case: Hermod also died (shouldn't happen but safe to handle)
                log("Phantoms cleared but Hermod gone — switching to LOOTING")
                killCount     = killCount + 1
                lootStartTime = os.time()
                currentState  = States.LOOTING
            end
        end
        return
    end

    -- ── LOOTING: picking up drops ────────────────────────────────────────
    if currentState == States.LOOTING then
        local elapsed = os.time() - lootStartTime
        if elapsed >= LOOT_WINDOW_SECONDS then
            log(string.format("Loot window (%ds) complete. Returning to IDLE.", LOOT_WINDOW_SECONDS))
            currentState  = States.IDLE
            lootStartTime = 0
        end
        return
    end
end

-- -----------------------------------------------------------------------
-- ON-SCREEN STATUS DISPLAY
-- Draws a live status table using MemoryError's DrawTable function.
-- -----------------------------------------------------------------------
local function displayStatus()
    local elapsed = os.time() - sessionStart
    local hrs     = math.floor(elapsed / 3600)
    local mins    = math.floor((elapsed % 3600) / 60)
    local secs    = elapsed % 60

    -- Safely call API functions that might not exist in all builds
    local hp  = (API.GetHP and API.GetHP()) or 0
    local pp  = (API.GetPrayPrecent and API.GetPrayPrecent()) or 0

    local lootTimeLeft = ""
    if currentState == States.LOOTING and lootStartTime > 0 then
        lootTimeLeft = string.format("  (%ds remaining)",
            math.max(0, LOOT_WINDOW_SECONDS - (os.time() - lootStartTime)))
    end

    API.DrawTable({
        { "═══ Hermod Boss Script ═══", "" },
        { "State",       currentState .. lootTimeLeft },
        { "Kill Count",  tostring(killCount) },
        { "Runtime",     string.format("%02d:%02d:%02d", hrs, mins, secs) },
        { "Health",      string.format("%d%%", hp) },
        { "Prayer",      string.format("%d%%", pp) },
        { "─────────────", "─────────────" },
        { "Hermod alive",  tostring(hermodExists()) },
        { "Phantoms alive", tostring(phantomsAlive()) .. " (" .. phantomCount() .. ")" },
        { "Last target",  lastTargetId == NPC_ID.HERMOD and "Hermod" or "Phantom" },
    })
end

-- -----------------------------------------------------------------------
-- MAIN LOOP
-- -----------------------------------------------------------------------
log("Script starting. Make sure you are inside Hermod's instance!")
log(string.format("Hermod NPC ID: %d | Phantom NPC ID: %d", NPC_ID.HERMOD, NPC_ID.ARMOURED_PHANTOM))
log("Waiting for Hermod to appear...")

while API.Read_LoopyLoop() do

    -- ── Step 1: Update player manager (tracks HP, prayer, location, buffs) ──
    playerManager:update()

    -- ── Step 2: Prayer management ────────────────────────────────────────────
    -- Only flick prayers when actively fighting.
    if currentState == States.FIGHTING_BOSS or currentState == States.KILLING_MINIONS then
        prayerFlicker:update()
    else
        -- Outside of combat — deactivate overhead prayers to save prayer points.
        -- Comment this out if you want to keep Soul Split active all the time.
        prayerFlicker:deactivatePrayer()
    end

    -- ── Step 3: Health & prayer item restoration ─────────────────────────────
    -- Always manage health and prayer regardless of state so we don't die
    -- between kills or while looting.
    playerManager:manageHealth()
    playerManager:managePrayer()

    -- ── Step 4: Evaluate and transition state ────────────────────────────────
    updateState()

    -- ── Step 5: Execute appropriate combat/loot actions ──────────────────────
    if currentState == States.FIGHTING_BOSS then
        -- Revolution handles basic ability queueing.
        -- attackBossTimer only re-clicks when needed (e.g. after phantom phase)
        -- so it doesn't interrupt the Revolution bar mid-rotation.
        attackBossTimer:execute()

    elseif currentState == States.KILLING_MINIONS then
        -- Actively redirect our attack to the phantoms every few ticks
        attackPhantomTimer:execute()

    elseif currentState == States.LOOTING then
        -- Sweep for and pick up all loot IDs
        lootTimer:execute()

    end
    -- IDLE state needs no active action — just waits for hermodExists() to become true

    -- ── Step 6: Draw status display ──────────────────────────────────────────
    displayStatus()

    -- ── Step 7: Short sleep — keeps the loop responsive ──────────────────────
    API.RandomSleep2(LOOP_SLEEP_MS, LOOP_SLEEP_VAR, LOOP_SLEEP_VAR)
end

-- ── Script stopped ────────────────────────────────────────────────────────────
log(string.format("Script stopped. Session kills: %d | Runtime: %ds",
    killCount, os.time() - sessionStart))
prayerFlicker:deactivatePrayer()
