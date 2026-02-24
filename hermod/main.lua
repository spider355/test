-- =============================================================================
--  HERMOD, THE SPIRIT OF WAR — Boss Script  [v2.2]
--  MemoryError RS3 Client | Lua
--
--  CHANGES v2.2:
--    - Wrapped all library .new() calls in pcall so a missing/mismatched
--      Sanson module degrades gracefully instead of crashing
--    - Wars Retreat auto-disabled if wars_retreat.lua constructor fails
--    - PrayerFlicker / PlayerManager fall back to stub if unavailable
--
--  FILE STRUCTURE:
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
-- =============================================================================

local API       = require("api")
local usertypes = require("usertypes")

-- ── SAFE REQUIRE ─────────────────────────────────────────────────────────────
-- Returns the module if it loads, or nil + prints a warning.
local function safeRequire(path)
    local ok, result = pcall(require, path)
    if ok then
        return result
    else
        print("[Hermod] WARNING: could not load " .. path .. " — " .. tostring(result))
        return nil
    end
end

local Timer         = safeRequire("core/timer")
local PlayerManager = safeRequire("core/player_manager")
local PrayerFlicker = safeRequire("core/prayer_flicker")
local WarsRetreat   = safeRequire("core/wars_retreat")
local GuiModule     = require("hermod/gui")   -- must exist

-- ── CONSTANTS ─────────────────────────────────────────────────────────────────
local NPC_ID = {
    HERMOD           = 30163,
    ARMOURED_PHANTOM = 30164,
}

local ALL_LOOT = {
    { id = 49394, name = "Hermodic plate",        key = "lootHermodicPlate", gpValue = 500000 },
    { id = 49395, name = "Hermod's armour spike", key = "lootArmourSpike",   gpValue = 200000 },
    { id = 536,   name = "Big bones",             key = "lootBigBones",      gpValue = 300    },
    { id = 995,   name = "Coins",                 key = "lootCoins",         gpValue = 1      },
}

local BOSS_ROOM_COORDS  = { x = 864, y = 1760, range = 35 }
local LOOP_SLEEP_MS     = 150
local LOOP_SLEEP_VAR    = 50
local LOOT_WINDOW_SEC   = 12
local RETURN_DELAY_MS   = 2000

-- ── STATES ────────────────────────────────────────────────────────────────────
local States = {
    IDLE              = "IDLE",
    WARS_RETREAT      = "WAR'S RETREAT",
    ENTERING_INSTANCE = "ENTERING",
    FIGHTING_BOSS     = "FIGHTING BOSS",
    KILLING_MINIONS   = "KILLING MINIONS",
    LOOTING           = "LOOTING",
    RETURNING         = "RETURNING",
}

-- ── RUNTIME ───────────────────────────────────────────────────────────────────
local currentState  = States.IDLE
local lootStartTime = 0
local returnStartT  = 0
local killCount     = 0
local sessionStart  = os.time()
local estimatedGP   = 0
local lastTargetId  = 0
local CFG           = nil

-- ── LOGGING ───────────────────────────────────────────────────────────────────
local function log(msg, module)
    if CFG then
        if module == "timer"  and not CFG.debugTimer  then return end
        if module == "player" and not CFG.debugPlayer then return end
        if module == "prayer" and not CFG.debugPrayer then return end
        if module == "wars"   and not CFG.debugWars   then return end
        if module == "debug"  and not CFG.debugMain   then return end
    end
    print(tostring(msg))
end

local function logMain(msg)  log(msg)          end
local function logDebug(msg) log(msg, "debug") end

-- ── UTILITIES ─────────────────────────────────────────────────────────────────
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

local function lootNearbyItems()
    for _, entry in ipairs(ALL_LOOT) do
        local enabled = not CFG or CFG[entry.key]
        if enabled then
            local ground = API.GetAllObjArrayInteract({entry.id}, 4, 8)
            if ground and #ground > 0 then
                logMain(string.format("[Loot] %s", entry.name))
                API.DoAction_Object1(0x5, API.OFF_ACT_GeneralObject_route0, {entry.id}, 8)
                API.RandomSleep2(400, 80, 80)
                if CFG and CFG.trackGp then
                    estimatedGP = estimatedGP + (entry.gpValue or 0)
                end
            end
        end
    end
end

-- ── GUI — wait for start ──────────────────────────────────────────────────────
local gui = GuiModule.new()

while API.Read_LoopyLoop() and not gui:isStarted() do
    gui:drawConfig()
    API.RandomSleep2(50, 10, 10)
end

if not API.Read_LoopyLoop() then return end

CFG = gui:getConfig()
logMain(string.format("[Hermod v2.2] Mode: %s | Curses: %s",
    CFG.useWarsRetreat and "Wars Retreat" or "Manual",
    tostring(CFG.useCurses)))

-- ── WAR'S RETREAT ─────────────────────────────────────────────────────────────
local warsRetreat = nil
if CFG.useWarsRetreat and WarsRetreat then
    -- Try to find the constructor — Sanson's modules may use .new() or the
    -- module itself may be callable. Try both.
    local constructor = nil
    if type(WarsRetreat.new) == "function" then
        constructor = WarsRetreat.new
    elseif type(WarsRetreat) == "function" then
        constructor = WarsRetreat
    end

    if constructor then
        local ok, result = pcall(constructor, WarsRetreat, {
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
        if ok and result then
            warsRetreat = result
            logMain("[Hermod] War's Retreat module ready.")
        else
            logMain("[Hermod] War's Retreat constructor failed — running manual mode.")
            CFG.useWarsRetreat = false
        end
    else
        logMain("[Hermod] War's Retreat has no recognised constructor — running manual mode.")
        CFG.useWarsRetreat = false
    end
end

-- ── PRAYER FLICKER ────────────────────────────────────────────────────────────
local prayerFlicker = nil
if PrayerFlicker and type(PrayerFlicker.new) == "function" then
    local SOUL_SPLIT    = (PrayerFlicker.CURSES and PrayerFlicker.CURSES.SOUL_SPLIT)
                       or (PrayerFlicker.PRAYERS and PrayerFlicker.PRAYERS.SOUL_SPLIT)
                       or 0
    local DEFLECT_MELEE = (PrayerFlicker.CURSES and PrayerFlicker.CURSES.DEFLECT_MELEE)
                       or (PrayerFlicker.PRAYERS and PrayerFlicker.PRAYERS.PROTECT_FROM_MELEE)
                       or 0

    local ok, pf = pcall(PrayerFlicker.new, PrayerFlicker, {
        defaultPrayer = SOUL_SPLIT,
        threats = {
            {
                name      = "Phantom melee",
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
    if ok and pf then
        prayerFlicker = pf
        logMain("[Hermod] PrayerFlicker ready.")
    else
        logMain("[Hermod] PrayerFlicker failed to init — prayer management disabled.")
    end
else
    logMain("[Hermod] PrayerFlicker not loaded — prayer management disabled.")
end

-- ── PLAYER MANAGER ────────────────────────────────────────────────────────────
local playerManager = nil
if PlayerManager and type(PlayerManager.new) == "function" then
    local ok, pm = pcall(PlayerManager.new, PlayerManager, {
        health = {
            normal   = { type = "percent", value = CFG.hpThresholdPct },
            critical = { type = "percent", value = CFG.hpCriticalPct  },
            special  = { type = "percent", value = CFG.hpSpecialPct   },
        },
        prayer = {
            normal   = { type = "percent", value = CFG.prayerThresholdPct },
            critical = { type = "percent", value = CFG.prayerCriticalPct  },
        },
        debugMode = CFG.debugPlayer,
    })
    if ok and pm then
        playerManager = pm
        logMain("[Hermod] PlayerManager ready.")
    else
        logMain("[Hermod] PlayerManager failed to init — HP/prayer management disabled.")
    end
else
    logMain("[Hermod] PlayerManager not loaded — HP/prayer management disabled.")
end

-- ── TIMERS ────────────────────────────────────────────────────────────────────
local attackBossTimer    = nil
local attackPhantomTimer = nil
local lootTimer          = nil

if Timer and type(Timer.new) == "function" then
    attackBossTimer = Timer.new(Timer, {
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
                logDebug("[Timer] Targeting Hermod")
                lastTargetId = NPC_ID.HERMOD
            end
            return attackNPC(NPC_ID.HERMOD)
        end,
    })

    attackPhantomTimer = Timer.new(Timer, {
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
    })

    lootTimer = Timer.new(Timer, {
        name     = "Loot",
        cooldown = 700,
        useTicks = false,
        condition = function() return currentState == States.LOOTING end,
        action    = function() lootNearbyItems(); return true end,
    })
    logMain("[Hermod] Timers ready.")
else
    logMain("[Hermod] Timer not loaded — will use direct attack calls instead.")
end

-- ── DIRECT ATTACK FALLBACK ────────────────────────────────────────────────────
-- Used when Timer module is unavailable.
local lastAttackMs = 0
local function directAttack(npcId, cooldownMs)
    local now = os.clock() * 1000
    if now - lastAttackMs >= cooldownMs then
        lastAttackMs = now
        return attackNPC(npcId)
    end
end

-- ── STATE MACHINE ─────────────────────────────────────────────────────────────
local function updateState()
    local hp             = (API.GetHP and API.GetHP()) or 100
    local hermodPresent  = hermodExists()
    local minionsPresent = phantomsAlive()

    if currentState == States.IDLE then
        if CFG.useWarsRetreat and warsRetreat then
            logMain("[State] IDLE → WARS_RETREAT")
            currentState = States.WARS_RETREAT
        else
            logMain("[State] IDLE → ENTERING (manual/fallback mode)")
            currentState = States.ENTERING_INSTANCE
        end

    elseif currentState == States.WARS_RETREAT then
        if warsRetreat and warsRetreat:run() then
            logMain("[State] Prep done → ENTERING_INSTANCE")
            currentState = States.ENTERING_INSTANCE
        end

    elseif currentState == States.ENTERING_INSTANCE then
        if CFG.waitForFullHp and hp < 95 then return end
        if hermodPresent then
            logMain("[State] Hermod found → FIGHTING_BOSS")
            lastTargetId = NPC_ID.HERMOD
            currentState = States.FIGHTING_BOSS
        end

    elseif currentState == States.FIGHTING_BOSS then
        if not hermodPresent then
            killCount     = killCount + 1
            lootStartTime = os.time()
            logMain(string.format("[State] Kill #%d → LOOTING", killCount))
            currentState = States.LOOTING
        elseif minionsPresent then
            logMain(string.format("[State] %d phantoms → KILLING_MINIONS", phantomCount()))
            lastTargetId = NPC_ID.ARMOURED_PHANTOM
            currentState = States.KILLING_MINIONS
        end

    elseif currentState == States.KILLING_MINIONS then
        if not minionsPresent then
            if hermodPresent then
                logMain("[State] Phantoms dead → FIGHTING_BOSS")
                lastTargetId = NPC_ID.HERMOD
                currentState = States.FIGHTING_BOSS
            else
                killCount     = killCount + 1
                lootStartTime = os.time()
                logMain(string.format("[State] Kill #%d → LOOTING", killCount))
                currentState = States.LOOTING
            end
        end

    elseif currentState == States.LOOTING then
        if os.time() - lootStartTime >= LOOT_WINDOW_SEC then
            lootStartTime = 0
            if CFG.useWarsRetreat and warsRetreat then
                returnStartT = os.clock() * 1000
                logMain("[State] Loot done → RETURNING")
                currentState = States.RETURNING
            else
                logMain("[State] Loot done → ENTERING (waiting for respawn)")
                currentState = States.ENTERING_INSTANCE
            end
        end

    elseif currentState == States.RETURNING then
        if (os.clock() * 1000) - returnStartT >= RETURN_DELAY_MS then
            logMain("[State] Teleporting to War's Retreat...")
            API.DoAction_Interface(0xffffffff, 0xffffffff, 0, 1465, 17, -1,
                API.OFF_ACT_GeneralInterface_route)
            API.RandomSleep2(2500, 300, 300)
            currentState = States.WARS_RETREAT
        end
    end
end

-- ── STATS ─────────────────────────────────────────────────────────────────────
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
    }
end

-- ── MAIN LOOP ─────────────────────────────────────────────────────────────────
logMain("[Hermod v2.2] Running.")
currentState = States.IDLE

while API.Read_LoopyLoop() do

    -- 1. HP / prayer management
    if playerManager then
        playerManager:update()
        playerManager:manageHealth()
        playerManager:managePrayer()
    end

    -- 2. Prayer flicker
    if prayerFlicker then
        local inCombat = currentState == States.FIGHTING_BOSS
                      or currentState == States.KILLING_MINIONS
        if inCombat then
            prayerFlicker:update()
        else
            prayerFlicker:deactivatePrayer()
        end
    end

    -- 3. State machine
    updateState()

    -- 4. Combat / loot actions
    if currentState == States.FIGHTING_BOSS then
        if attackBossTimer then
            attackBossTimer:execute()
        else
            directAttack(NPC_ID.HERMOD, 1800)
        end

    elseif currentState == States.KILLING_MINIONS then
        if attackPhantomTimer then
            attackPhantomTimer:execute()
        else
            directAttack(NPC_ID.ARMOURED_PHANTOM, 1200)
        end

    elseif currentState == States.LOOTING then
        if lootTimer then
            lootTimer:execute()
        else
            lootNearbyItems()
            API.RandomSleep2(700, 100, 100)
        end
    end

    -- 5. Status overlay
    gui:drawStatus(buildStats())

    -- 6. Sleep
    API.RandomSleep2(LOOP_SLEEP_MS, LOOP_SLEEP_VAR, LOOP_SLEEP_VAR)
end

-- ── CLEANUP ───────────────────────────────────────────────────────────────────
if prayerFlicker then prayerFlicker:deactivatePrayer() end
logMain(string.format("[Hermod] Stopped. Kills: %d | GP: ~%s | Runtime: %ds",
    killCount, commify(estimatedGP), os.time() - sessionStart))
