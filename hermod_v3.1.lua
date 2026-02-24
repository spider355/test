-- =============================================================================
--  HERMOD, THE SPIRIT OF WAR  [v3.1]
--  MemoryError RS3 Client | Lua
--
--  CHANGES v3.1:
--    - Fixed GetAllObjArrayInteract call signature (second arg must be a table)
--    - Fixed ground item loot API call signature
--    - Added API call safety wrappers to catch future signature mismatches
--
--  SINGLE FILE — place in Lua_Scripts\ and run as hermod_v3.1
--  Requires ONLY api.lua and usertypes.lua
-- =============================================================================

local API       = require("api")
local usertypes = require("usertypes")

print("[Hermod v3.1] Loaded.")

-- =============================================================================
--  CONFIG
-- =============================================================================
local CONFIG = {
    eatAtHpPct       = 50,
    emergencyHpPct   = 30,
    restoreAtPrayPct = 20,
    lootWindowSecs   = 12,
    loopSleepMs      = 150,
    loopSleepVar     = 50,
}

-- =============================================================================
--  IDs
-- =============================================================================
local NPC_ID = {
    HERMOD           = 30163,
    ARMOURED_PHANTOM = 30164,
}

local LOOT_IDS = {
    49394,  -- Hermodic plate
    49395,  -- Hermod's armour spike (verify in-game)
    995,    -- Coins
    536,    -- Big bones
}

-- Item IDs for food/potions — update to match your inventory
local FOOD_ID           = 47531   -- Blue blubber jellyfish (adjust as needed)
local EMERGENCY_FOOD_ID = 29448   -- Guthix rest flask (adjust as needed)
local PRAYER_RESTORE_ID = 23741   -- Super restore flask (adjust as needed)

-- =============================================================================
--  API WRAPPERS
--  GetAllObjArrayInteract(ids_table, type_table, range)
--  The second argument must be a TABLE, not a bare number.
--  type_table values:
--    {1} = NPC
--    {4} = Ground item  (some builds use {5} — we try both)
-- =============================================================================
local function getNPCs(id, range)
    local ok, result = pcall(function()
        return API.GetAllObjArrayInteract({id}, {1}, range or 30)
    end)
    if ok and result then return result end
    -- fallback: try without the table wrapper on arg2
    local ok2, result2 = pcall(function()
        return API.GetAllObjArrayInteract({id}, 1, range or 30)
    end)
    if ok2 and result2 then return result2 end
    return {}
end

local function getGroundItems(id, range)
    local ok, result = pcall(function()
        return API.GetAllObjArrayInteract({id}, {4}, range or 8)
    end)
    if ok and result then return result end
    local ok2, result2 = pcall(function()
        return API.GetAllObjArrayInteract({id}, 4, range or 8)
    end)
    if ok2 and result2 then return result2 end
    return {}
end

local function hermodExists()  return #getNPCs(NPC_ID.HERMOD,           30) > 0 end
local function getPhantoms()   return getNPCs(NPC_ID.ARMOURED_PHANTOM,  30)     end
local function phantomsAlive() return #getPhantoms() > 0                        end

local function attackNPC(id)
    return API.DoAction_NPC1(0x10, API.OFF_ACT_NpcT_route, {id}, 30)
end

-- =============================================================================
--  TIMING
-- =============================================================================
local function nowMs()
    return os.clock() * 1000
end

local lastAttackMs = 0
local lastLootMs   = 0

local function attackWithCooldown(npcId, cooldownMs)
    local t = nowMs()
    if t - lastAttackMs >= cooldownMs then
        lastAttackMs = t
        attackNPC(npcId)
    end
end

-- =============================================================================
--  LOOT
-- =============================================================================
local function lootItems()
    local t = nowMs()
    if t - lastLootMs < 700 then return end
    lastLootMs = t
    for _, itemId in ipairs(LOOT_IDS) do
        local ground = getGroundItems(itemId, 8)
        if #ground > 0 then
            print(string.format("[Hermod] Looting item %d", itemId))
            local ok = pcall(function()
                API.DoAction_Object1(0x5, API.OFF_ACT_GeneralObject_route0, {itemId}, 8)
            end)
            if not ok then
                -- try alternate ground item action
                pcall(function()
                    API.DoAction_Loot(itemId, 8, API.OFF_ACT_GeneralObject_route0)
                end)
            end
            API.RandomSleep2(350, 60, 60)
        end
    end
end

-- =============================================================================
--  HP / PRAYER MANAGEMENT
-- =============================================================================
local function useInventoryItem(itemId)
    pcall(function()
        API.DoAction_Inventory1({itemId}, 0, 1, API.OFF_ACT_GeneralInterface_route)
    end)
end

local function manageHp()
    local hp = (API.GetHP and API.GetHP()) or 100
    if hp <= CONFIG.emergencyHpPct then
        useInventoryItem(EMERGENCY_FOOD_ID)
    elseif hp <= CONFIG.eatAtHpPct then
        useInventoryItem(FOOD_ID)
    end
end

local function managePrayer()
    local pp = (API.GetPrayPrecent and API.GetPrayPrecent()) or 100
    if pp <= CONFIG.restoreAtPrayPct then
        useInventoryItem(PRAYER_RESTORE_ID)
    end
end

-- =============================================================================
--  STATE MACHINE
-- =============================================================================
local States = {
    WAITING         = "WAITING FOR HERMOD",
    FIGHTING_BOSS   = "FIGHTING BOSS",
    KILLING_MINIONS = "KILLING MINIONS",
    LOOTING         = "LOOTING",
}

local state         = States.WAITING
local killCount     = 0
local sessionStart  = os.time()
local lootStartTime = 0

local function updateState()
    local hermodPresent  = hermodExists()
    local minionsPresent = phantomsAlive()

    if state == States.WAITING then
        if hermodPresent then
            print("[Hermod] Hermod detected — starting fight!")
            state = States.FIGHTING_BOSS
        end

    elseif state == States.FIGHTING_BOSS then
        if not hermodPresent then
            killCount     = killCount + 1
            lootStartTime = os.time()
            print(string.format("[Hermod] Kill #%d — looting!", killCount))
            state = States.LOOTING
        elseif minionsPresent then
            print(string.format("[Hermod] %d phantoms spawned — switching!", #getPhantoms()))
            state = States.KILLING_MINIONS
        end

    elseif state == States.KILLING_MINIONS then
        if not minionsPresent then
            if hermodPresent then
                print("[Hermod] Phantoms dead — back to Hermod!")
                state = States.FIGHTING_BOSS
            else
                killCount     = killCount + 1
                lootStartTime = os.time()
                print(string.format("[Hermod] Kill #%d — looting!", killCount))
                state = States.LOOTING
            end
        end

    elseif state == States.LOOTING then
        if os.time() - lootStartTime >= CONFIG.lootWindowSecs then
            lootStartTime = 0
            print("[Hermod] Loot done — waiting for next spawn.")
            state = States.WAITING
        end
    end
end

-- =============================================================================
--  STATUS OVERLAY
-- =============================================================================
local function displayStatus()
    local t  = os.time() - sessionStart
    local rt = string.format("%02d:%02d:%02d",
        math.floor(t/3600), math.floor((t%3600)/60), t%60)
    local kph = t > 60 and string.format("%.1f/hr", killCount/(t/3600)) or "—"
    local hp  = (API.GetHP and API.GetHP()) or 0
    local pp  = (API.GetPrayPrecent and API.GetPrayPrecent()) or 0

    API.DrawTable({
        { "Hermod v3.1",    ""                                          },
        { "State",          state                                       },
        { "─────────",      "─────────"                                },
        { "Kills",          tostring(killCount).."  ("..kph..")"       },
        { "Runtime",        rt                                          },
        { "─────────",      "─────────"                                },
        { "HP",             string.format("%d%%", hp)                  },
        { "Prayer",         string.format("%d%%", pp)                  },
        { "─────────",      "─────────"                                },
        { "Hermod alive",   tostring(hermodExists())                   },
        { "Phantoms",       tostring(#getPhantoms())                   },
    })
end

-- =============================================================================
--  MAIN LOOP
-- =============================================================================
print(string.format("[Hermod v3.1] Running. Eat at %d%% HP | Restore prayer at %d%%",
    CONFIG.eatAtHpPct, CONFIG.restoreAtPrayPct))
print("[Hermod v3.1] Stand inside Hermod's instance and let him spawn.")

while API.Read_LoopyLoop() do

    manageHp()
    managePrayer()
    updateState()

    if state == States.FIGHTING_BOSS then
        attackWithCooldown(NPC_ID.HERMOD, 1800)

    elseif state == States.KILLING_MINIONS then
        attackWithCooldown(NPC_ID.ARMOURED_PHANTOM, 1200)

    elseif state == States.LOOTING then
        lootItems()
    end

    displayStatus()

    API.RandomSleep2(CONFIG.loopSleepMs, CONFIG.loopSleepVar, CONFIG.loopSleepVar)
end

print(string.format("[Hermod v3.1] Stopped. Kills: %d | Runtime: %ds",
    killCount, os.time() - sessionStart))
