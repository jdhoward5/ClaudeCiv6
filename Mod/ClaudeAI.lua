-- ClaudeAI.lua - Claude AI Integration for Civilization VI
-- This script works with the version.dll proxy that registers SendGameStateToClaudeAPI
print("========================================")
print("ClaudeAI: Mod script loading...")
print("========================================")

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

ClaudeAI = ClaudeAI or {}

ClaudeAI.Config = {
    -- Which player ID should Claude control
    -- Set to -1 to auto-detect the local human player
    -- Set to a specific ID (0, 1, 2, etc.) to control a specific player
    controlledPlayerID = -1,
    -- Is Claude AI enabled?
    enabled = true,
    -- Enable debug logging
    debugLogging = true,
    -- Auto-process turns when it's Claude's turn (set to false to require manual trigger)
    autoProcessTurn = true,
}

-- ============================================================================
-- CONSTANTS
-- Centralized magic strings and configuration values
-- ============================================================================

-- Property keys for cross-context communication via Game.SetProperty/GetProperty
local PROPERTY_KEYS = {
    -- UI Requests (Gameplay sets, UI reads and executes)
    REQUEST_END_TURN = "ClaudeAI_RequestEndTurn",
    REQUEST_RESEARCH = "ClaudeAI_RequestResearch",
    REQUEST_CIVIC = "ClaudeAI_RequestCivic",
    REQUEST_PRODUCTION = "ClaudeAI_RequestProduction",
    REQUEST_GOVERNMENT = "ClaudeAI_RequestGovernment",
    REQUEST_POLICY = "ClaudeAI_RequestPolicy",
    REQUEST_DIPLOMACY = "ClaudeAI_RequestDiplomacy",
    REQUEST_PLACE_DISTRICT = "ClaudeAI_RequestPlaceDistrict",
    REQUEST_PURCHASE = "ClaudeAI_RequestPurchase",
    DISMISS_NOTIFICATIONS = "ClaudeAI_DismissNotifications",
    AUTO_DISMISS_DIPLOMACY = "ClaudeAI_AutoDismissDiplomacy",

    -- State flags
    IS_THINKING = "ClaudeAI_IsThinking",

    -- Persistent data
    STRATEGY_NOTES = "ClaudeAI_StrategyNotes",
    TACTICAL_NOTES = "ClaudeAI_TacticalNotes",
    LONG_RESPONSE = "ClaudeAI_LongResponse",
}

-- Keys for ExposedMembers (shared between contexts)
local EXPOSED_MEMBER_KEYS = {
    IS_THINKING = "ClaudeAI_IsThinking",
    GOVERNMENT_INFO = "ClaudeAI_GovernmentInfo",
    CIVIC_PROGRESS = "ClaudeAI_CivicProgress",
}

-- Limits and configuration constants
local LIMITS = {
    MAX_STRATEGY_NOTES_LENGTH = 4000,
    ASYNC_TIMEOUT_SECONDS = 60,
    POLL_LOG_INTERVAL = 500,  -- Log every N polls
    MAX_JSON_PREVIEW_LENGTH = 500,
}

-- ============================================================================
-- LOCAL HELPER UTILITIES
-- These reduce code duplication for common patterns throughout the mod
-- ============================================================================

--- Safe execution wrapper with context-aware error logging
---@param context string Description of what operation is being performed
---@param fn function The function to execute
---@return boolean success Whether the operation succeeded
---@return any result The result or error message
local function SafeExecute(context, fn)
    local success, result = pcall(fn)
    if not success then
        print("[ClaudeAI] ERROR in " .. context .. ": " .. tostring(result))
    end
    return success, result
end

-- Safe pcall wrapper with fallback value
-- Usage: local value = SafeCall(function() return obj:GetSomething() end, defaultValue)
local function SafeCall(fn, fallback)
    local success, result = pcall(fn)
    if success then return result end
    return fallback
end

-- Safe property/method getter on an object
-- Usage: local combat = SafeGet(pUnit, "GetCombat") or 0
-- Usage with args: local yield = SafeGet(pCity, "GetYield", YieldTypes.PRODUCTION) or 0
local function SafeGet(obj, method, arg1, arg2, arg3)
    if not obj then return nil end
    if not obj[method] then return nil end
    -- Avoid varargs/unpack for HavokScript compatibility - support up to 3 args
    if arg1 == nil then
        return SafeCall(function() return obj[method](obj) end, nil)
    elseif arg2 == nil then
        return SafeCall(function() return obj[method](obj, arg1) end, nil)
    elseif arg3 == nil then
        return SafeCall(function() return obj[method](obj, arg1, arg2) end, nil)
    else
        return SafeCall(function() return obj[method](obj, arg1, arg2, arg3) end, nil)
    end
end

-- Find GameInfo entry by index (replaces 20+ identical for loops)
-- Usage: local techInfo = FindGameInfoByIndex(GameInfo.Technologies, techIndex)
local function FindGameInfoByIndex(gameInfoTable, index)
    if not gameInfoTable then return nil end
    if index == nil or index < 0 then return nil end
    for row in gameInfoTable() do
        if row.Index == index then return row end
    end
    return nil
end

-- Find GameInfo entry by type name
-- Usage: local unitInfo = FindGameInfoByType(GameInfo.Units, "UNIT_WARRIOR")
local function FindGameInfoByType(gameInfoTable, typeName)
    if not gameInfoTable or not typeName then return nil end
    return gameInfoTable[typeName]
end

-- Get a type name from GameInfo by index, with prefix stripping
-- Usage: local name = GetTypeNameByIndex(GameInfo.Terrains, terrainType, "TerrainType", "TERRAIN_")
local function GetTypeNameByIndex(gameInfoTable, index, fieldName, prefix)
    local info = FindGameInfoByIndex(gameInfoTable, index)
    if not info then return nil end
    local name = info[fieldName]
    if name and prefix and name:find(prefix) == 1 then
        name = name:sub(#prefix + 1)
    end
    return name
end

-- ============================================================================
-- GLOBAL WONDER TRACKING
-- Track which wonders have been built globally so we don't offer them
-- ============================================================================

ClaudeAI.BuiltWonders = ClaudeAI.BuiltWonders or {}

-- Called when any wonder is completed in the game
function ClaudeAI.OnWonderCompleted(x, y, buildingIndex, playerID, cityID, iPercentComplete, iUnknown)
    -- Get the building type name
    local buildingType = nil
    pcall(function()
        if GameInfo.Buildings then
            local buildingInfo = GameInfo.Buildings[buildingIndex]
            if buildingInfo then
                buildingType = buildingInfo.BuildingType
            end
        end
    end)

    if buildingType then
        ClaudeAI.BuiltWonders[buildingType] = true
        print("[ClaudeAI] Wonder completed: " .. buildingType .. " by player " .. tostring(playerID))
    end
end

-- Alternative: Track via BuildingAddedToMap event (more reliable)
function ClaudeAI.OnBuildingAddedToMap(x, y, buildingIndex, playerID, cityID, iPercentComplete)
    pcall(function()
        if GameInfo.Buildings then
            local buildingInfo = GameInfo.Buildings[buildingIndex]
            if buildingInfo then
                local buildingType = buildingInfo.BuildingType or "UNKNOWN"

                -- Track wonders globally
                if buildingInfo.IsWonder then
                    ClaudeAI.BuiltWonders[buildingType] = true
                    print("[ClaudeAI] Wonder built: " .. buildingType .. " by player " .. tostring(playerID))
                end

                -- Log ALL buildings for Claude's controlled player to debug mystery builds
                if playerID == ClaudeAI.Config.controlledPlayerID then
                    -- Check if this is a wall or defensive building
                    local isDefensive = buildingType:find("WALL") or buildingType:find("DEFENSE") or buildingType:find("CASTLE")
                    if isDefensive then
                        print("[ClaudeAI] *** MYSTERY BUILD DETECTED *** " .. buildingType .. " appeared at (" .. x .. "," .. y .. ") for player " .. playerID .. " city " .. tostring(cityID))
                        print("[ClaudeAI] *** This building was NOT built through Claude's build queue! ***")
                    else
                        print("[ClaudeAI] Building added: " .. buildingType .. " for player " .. playerID)
                    end
                end
            end
        end
    end)
end

-- Check if a wonder has been built anywhere in the world
function ClaudeAI.IsWonderBuilt(buildingType)
    return ClaudeAI.BuiltWonders[buildingType] == true
end

-- Scan all existing wonders at game load (in case loading a save)
function ClaudeAI.ScanExistingWonders()
    ClaudeAI.BuiltWonders = {}  -- Reset

    pcall(function()
        -- Iterate through all players and their cities to find built wonders
        local playerCount = PlayerManager.GetAliveMajorsCount() + PlayerManager.GetAliveMinorsCount()

        for playerID = 0, 62 do  -- Max player ID
            local pPlayer = Players[playerID]
            if pPlayer then
                local pCities = pPlayer:GetCities()
                if pCities then
                    for _, pCity in pCities:Members() do
                        local pBuildings = pCity:GetBuildings()
                        if pBuildings then
                            -- Check each wonder
                            if GameInfo.Buildings then
                                for row in GameInfo.Buildings() do
                                    if row.IsWonder then
                                        local hasWonder = false
                                        pcall(function()
                                            hasWonder = pBuildings:HasBuilding(row.Index)
                                        end)
                                        if hasWonder then
                                            ClaudeAI.BuiltWonders[row.BuildingType] = true
                                            print("[ClaudeAI] Found existing wonder: " .. row.BuildingType)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    local count = 0
    for _ in pairs(ClaudeAI.BuiltWonders) do count = count + 1 end
    print("[ClaudeAI] Scanned existing wonders: " .. count .. " found")
end

-- ============================================================================
-- EXPOSED MEMBERS INITIALIZATION
-- ExposedMembers is used to communicate between Gameplay and UI contexts
-- The UI context has UnitManager.RequestOperation which gameplay doesn't have
-- ============================================================================

if not ExposedMembers then
    ExposedMembers = {}
    print("[ClaudeAI] ExposedMembers table initialized")
else
    print("[ClaudeAI] ExposedMembers table already exists")
end

-- ============================================================================
-- FIND LOCAL PLAYER
-- ============================================================================

function ClaudeAI.FindLocalPlayer()
    print("[ClaudeAI] Looking for local human player...")

    -- Try to get the local player directly (most reliable method)
    if Game and Game.GetLocalPlayer then
        local localPlayerID = Game.GetLocalPlayer()
        if localPlayerID and localPlayerID >= 0 then
            print("[ClaudeAI] Found local player via Game.GetLocalPlayer(): " .. tostring(localPlayerID))
            return localPlayerID
        end
    end

    -- Fallback: Check PlayerManager for human players
    if not PlayerManager then
        print("[ClaudeAI] ERROR: PlayerManager not available")
        return -1
    end

    local aliveMajors = PlayerManager.GetAliveMajors()
    if not aliveMajors then
        print("[ClaudeAI] ERROR: GetAliveMajors returned nil")
        return -1
    end

    print("[ClaudeAI] DEBUG: GetAliveMajors returned " .. tostring(#aliveMajors) .. " players")
    for i, playerObj in ipairs(aliveMajors) do
        print("[ClaudeAI] DEBUG: Checking player at index " .. tostring(i))
        if playerObj then
            local playerID = playerObj:GetID()
            local isHuman = playerObj:IsHuman()
            print("[ClaudeAI] DEBUG: Player ID=" .. tostring(playerID) .. ", IsHuman=" .. tostring(isHuman))
            if isHuman then
                print("[ClaudeAI] Found human player with ID: " .. tostring(playerID))
                return playerID
            end
        else
            print("[ClaudeAI] DEBUG: Player at index " .. i .. " is nil")
        end
    end

    print("[ClaudeAI] No human players found")
    return -1
end

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

function ClaudeAI.Log(message)
    if ClaudeAI.Config.debugLogging then
        print("[ClaudeAI] " .. tostring(message))
    end
end

-- ============================================================================
-- UI NOTIFICATION FUNCTIONS (via LuaEvents)
-- ============================================================================

function ClaudeAI.NotifyPlayerSet(playerID, civName, leaderName)
    if LuaEvents and LuaEvents.ClaudeAI_PlayerSet then
        LuaEvents.ClaudeAI_PlayerSet(playerID, civName, leaderName)
        ClaudeAI.Log("Notified UI: Player set to " .. tostring(playerID))
    end
end

-- Clear all UI request properties (called at start and end of turn)
function ClaudeAI.ClearUIRequestProperties()
    if Game and Game.SetProperty then
        Game.SetProperty(PROPERTY_KEYS.REQUEST_END_TURN, 0)
        Game.SetProperty(PROPERTY_KEYS.REQUEST_RESEARCH, "")
        Game.SetProperty(PROPERTY_KEYS.REQUEST_CIVIC, "")
        Game.SetProperty(PROPERTY_KEYS.REQUEST_PRODUCTION, "")
        Game.SetProperty(PROPERTY_KEYS.REQUEST_GOVERNMENT, "")
        Game.SetProperty(PROPERTY_KEYS.REQUEST_POLICY, "")
        Game.SetProperty(PROPERTY_KEYS.DISMISS_NOTIFICATIONS, 0)
        ClaudeAI.Log("Cleared UI request properties")
    end
end

function ClaudeAI.NotifyTurnStarted(playerID, turn)
    -- Clear any stale UI request properties from previous turn
    ClaudeAI.ClearUIRequestProperties()

    -- Fire LuaEvent to UI context (don't check if it exists - LuaEvents are created on-demand)
    if LuaEvents then
        ClaudeAI.Log("Firing LuaEvents.ClaudeAI_TurnStarted to UI context")
        LuaEvents.ClaudeAI_TurnStarted(playerID, turn)
    end
end

function ClaudeAI.NotifyTurnEnded(playerID)
    -- Fire LuaEvent to UI context
    if LuaEvents then
        LuaEvents.ClaudeAI_TurnEnded(playerID)
    end

    -- Clear the thinking indicator (UI can't do this because SetProperty doesn't work there)
    ClaudeAI.NotifyThinking(false)

    -- NOTE: Do NOT clear request properties here - UI needs time to poll and process them
    -- Properties are cleared at the start of the next turn in NotifyTurnStarted
end

function ClaudeAI.NotifyThinking(isThinking)
    ClaudeAI.Log("NotifyThinking called with: " .. tostring(isThinking))

    -- Use Game.SetProperty for cross-context communication (truly shared between contexts)
    if Game and Game.SetProperty then
        local value = isThinking and 1 or 0  -- Properties work better with numbers
        Game.SetProperty(PROPERTY_KEYS.IS_THINKING, value)
        ClaudeAI.Log("Set Game property IS_THINKING = " .. tostring(value))
    else
        ClaudeAI.Log("WARNING: Game.SetProperty not available!")
    end

    -- Also set ExposedMembers as fallback
    if ExposedMembers then
        ExposedMembers[EXPOSED_MEMBER_KEYS.IS_THINKING] = isThinking
    end
end

-- Request the UI context to end the turn (uses Game.SetProperty for cross-context communication)
function ClaudeAI.RequestEndTurn()
    ClaudeAI.Log("Requesting UI to end turn...")
    if Game and Game.SetProperty then
        Game.SetProperty(PROPERTY_KEYS.REQUEST_END_TURN, 1)
        ClaudeAI.Log("Set REQUEST_END_TURN = 1")
        return true
    else
        ClaudeAI.Log("WARNING: Game.SetProperty not available")
        return false
    end
end

-- Request the UI context to set research (for human players, dismisses modal)
function ClaudeAI.RequestResearch(playerID, techHash)
    ClaudeAI.Log("Requesting UI to set research: " .. tostring(techHash))
    if Game and Game.SetProperty then
        Game.SetProperty(PROPERTY_KEYS.REQUEST_RESEARCH, tostring(playerID) .. "," .. tostring(techHash))
        ClaudeAI.Log("Set REQUEST_RESEARCH")
        return true
    end
    return false
end

-- Request the UI context to set civic (for human players, dismisses modal)
function ClaudeAI.RequestCivic(playerID, civicHash)
    ClaudeAI.Log("Requesting UI to set civic: " .. tostring(civicHash))
    if Game and Game.SetProperty then
        Game.SetProperty(PROPERTY_KEYS.REQUEST_CIVIC, tostring(playerID) .. "," .. tostring(civicHash))
        ClaudeAI.Log("Set REQUEST_CIVIC")
        return true
    end
    return false
end

-- Request the UI context to set city production (for human players)
function ClaudeAI.RequestProduction(playerID, cityID, productionType, productionHash)
    ClaudeAI.Log("Requesting UI to set production: " .. tostring(productionType) .. " hash=" .. tostring(productionHash))
    if Game and Game.SetProperty then
        local requestStr = tostring(playerID) .. "," .. tostring(cityID) .. "," .. tostring(productionType) .. "," .. tostring(productionHash)
        Game.SetProperty(PROPERTY_KEYS.REQUEST_PRODUCTION, requestStr)
        ClaudeAI.Log("Set REQUEST_PRODUCTION")
        return true
    end
    return false
end

-- Request the UI context to change government (for human players)
function ClaudeAI.RequestGovernment(playerID, governmentHash)
    ClaudeAI.Log("Requesting UI to change government: hash=" .. tostring(governmentHash))
    if Game and Game.SetProperty then
        Game.SetProperty(PROPERTY_KEYS.REQUEST_GOVERNMENT, tostring(playerID) .. "," .. tostring(governmentHash))
        ClaudeAI.Log("Set REQUEST_GOVERNMENT")
        return true
    end
    return false
end

-- Request the UI context to set policies (for human players)
-- policyAssignments is a table: {[slotIndex] = policyHash, ...}
function ClaudeAI.RequestPolicy(playerID, policyAssignments)
    ClaudeAI.Log("Requesting UI to set policies")
    if Game and Game.SetProperty then
        local parts = {tostring(playerID)}
        for slotIndex, policyHash in pairs(policyAssignments) do
            table.insert(parts, tostring(slotIndex) .. ":" .. tostring(policyHash))
        end
        local requestStr = table.concat(parts, ",")
        Game.SetProperty(PROPERTY_KEYS.REQUEST_POLICY, requestStr)
        ClaudeAI.Log("Set REQUEST_POLICY: " .. requestStr)
        return true
    end
    return false
end

-- Request the UI to dismiss blocking notifications (research/civic completed, etc.)
function ClaudeAI.RequestDismissNotifications()
    ClaudeAI.Log("Requesting UI to dismiss blocking notifications")
    if Game and Game.SetProperty then
        Game.SetProperty(PROPERTY_KEYS.DISMISS_NOTIFICATIONS, 1)
        ClaudeAI.Log("Set DISMISS_NOTIFICATIONS = 1")
        return true
    end
    return false
end

-- Request the UI to perform a diplomacy action
-- Actions: "dismiss", "respond,playerID,responseType", "declare_war,playerID", "make_peace,playerID"
function ClaudeAI.RequestDiplomacyAction(actionStr)
    ClaudeAI.Log("Requesting diplomacy action: " .. tostring(actionStr))
    if Game and Game.SetProperty then
        Game.SetProperty(PROPERTY_KEYS.REQUEST_DIPLOMACY, actionStr)
        ClaudeAI.Log("Set REQUEST_DIPLOMACY = " .. actionStr)
        return true
    end
    return false
end

-- Enable/disable auto-dismiss of diplomacy popups (first meeting, etc.)
function ClaudeAI.SetAutoDismissDiplomacy(enabled)
    if Game and Game.SetProperty then
        Game.SetProperty(PROPERTY_KEYS.AUTO_DISMISS_DIPLOMACY, enabled and 1 or 0)
        ClaudeAI.Log("Set AUTO_DISMISS_DIPLOMACY: " .. tostring(enabled))
        return true
    end
    return false
end

-- ============================================================================
-- STRATEGY NOTES - Persistent memory across turns
-- ============================================================================

-- Get the current strategy notes (persisted via Game.SetProperty)
function ClaudeAI.GetStrategyNotes()
    local result = nil
    pcall(function()
        if Game and Game.GetProperty then
            local notes = Game.GetProperty(PROPERTY_KEYS.STRATEGY_NOTES)
            if notes and type(notes) == "string" and notes ~= "" then
                result = notes
            end
        end
    end)
    return result
end

-- Update strategy notes (persisted across turns)
function ClaudeAI.SetStrategyNotes(notes)
    local success = false
    pcall(function()
        if Game and Game.SetProperty then
            -- Limit notes length to prevent excessive memory usage
            if notes and #notes > LIMITS.MAX_STRATEGY_NOTES_LENGTH then
                notes = notes:sub(1, LIMITS.MAX_STRATEGY_NOTES_LENGTH)
                ClaudeAI.Log("WARNING: Strategy notes truncated to " .. LIMITS.MAX_STRATEGY_NOTES_LENGTH .. " characters")
            end
            Game.SetProperty(PROPERTY_KEYS.STRATEGY_NOTES, notes or "")
            ClaudeAI.Log("Updated strategy notes (" .. tostring(notes and #notes or 0) .. " chars)")
            success = true
        end
    end)
    return success
end

-- Get turn-specific tactical notes (cleared each turn)
function ClaudeAI.GetTacticalNotes()
    local result = nil
    pcall(function()
        if Game and Game.GetProperty then
            local notes = Game.GetProperty(PROPERTY_KEYS.TACTICAL_NOTES)
            if notes and type(notes) == "string" and notes ~= "" then
                result = notes
            end
        end
    end)
    return result
end

-- Decode government info JSON string into a Lua table
-- Parses the JSON from UI context so it can be properly nested in game state
function ClaudeAI.DecodeGovernmentInfoJSON(jsonStr)
    if not jsonStr or jsonStr == "" then return nil end

    local result = {
        currentGovernment = nil,
        availableGovernments = {},
        policySlots = {},
        availablePolicies = {},
    }

    -- Extract currentGovernment
    result.currentGovernment = jsonStr:match('"currentGovernment"%s*:%s*"([^"]+)"')

    -- Extract availableGovernments array
    local govArrayStart = jsonStr:find('"availableGovernments"%s*:%s*%[')
    if govArrayStart then
        local govArrayEnd = jsonStr:find('%]', govArrayStart)
        if govArrayEnd then
            local govArrayStr = jsonStr:sub(govArrayStart, govArrayEnd)
            for gov in govArrayStr:gmatch('"(GOVERNMENT_[^"]+)"') do
                table.insert(result.availableGovernments, gov)
            end
        end
    end

    -- Extract policySlots array - each has slotIndex, slotType, currentPolicy
    local slotsStart = jsonStr:find('"policySlots"%s*:%s*%[')
    if slotsStart then
        -- Find the matching closing bracket for the array
        local bracketCount = 0
        local slotsEnd = nil
        for i = slotsStart, #jsonStr do
            local c = jsonStr:sub(i, i)
            if c == '[' then bracketCount = bracketCount + 1
            elseif c == ']' then
                bracketCount = bracketCount - 1
                if bracketCount == 0 then
                    slotsEnd = i
                    break
                end
            end
        end

        if slotsEnd then
            local slotsStr = jsonStr:sub(slotsStart, slotsEnd)
            -- Parse each slot object
            for slotObj in slotsStr:gmatch('{[^{}]+}') do
                local slot = {
                    slotIndex = tonumber(slotObj:match('"slotIndex"%s*:%s*(%d+)')),
                    slotType = slotObj:match('"slotType"%s*:%s*"([^"]+)"'),
                    currentPolicy = slotObj:match('"currentPolicy"%s*:%s*"([^"]+)"'),
                }
                if slot.slotIndex then
                    table.insert(result.policySlots, slot)
                end
            end
        end
    end

    -- Extract availablePolicies array - each has policy name and slotType
    local policiesStart = jsonStr:find('"availablePolicies"%s*:%s*%[')
    if policiesStart then
        -- Find the matching closing bracket for the array
        local bracketCount = 0
        local policiesEnd = nil
        for i = policiesStart, #jsonStr do
            local c = jsonStr:sub(i, i)
            if c == '[' then bracketCount = bracketCount + 1
            elseif c == ']' then
                bracketCount = bracketCount - 1
                if bracketCount == 0 then
                    policiesEnd = i
                    break
                end
            end
        end

        if policiesEnd then
            local policiesStr = jsonStr:sub(policiesStart, policiesEnd)
            -- Parse each policy object
            for policyObj in policiesStr:gmatch('{[^{}]+}') do
                local policy = {
                    policy = policyObj:match('"policy"%s*:%s*"([^"]+)"'),
                    slotType = policyObj:match('"slotType"%s*:%s*"([^"]+)"'),
                }
                if policy.policy then
                    table.insert(result.availablePolicies, policy)
                end
            end
        end
    end

    return result
end

-- Get government info from UI context (stored via ExposedMembers)
-- Returns a Lua table (decoded from JSON) for proper inclusion in game state
function ClaudeAI.GetGovernmentInfoFromUI()
    local result = nil
    pcall(function()
        -- UI context stores government info in ExposedMembers (Game.SetProperty doesn't work there)
        if ExposedMembers and ExposedMembers[EXPOSED_MEMBER_KEYS.GOVERNMENT_INFO] then
            local info = ExposedMembers[EXPOSED_MEMBER_KEYS.GOVERNMENT_INFO]
            if info and type(info) == "string" and info ~= "" then
                -- Decode the JSON string into a Lua table
                result = ClaudeAI.DecodeGovernmentInfoJSON(info)
                if result then
                    local slotCount = result.policySlots and #result.policySlots or 0
                    local policyCount = result.availablePolicies and #result.availablePolicies or 0
                    ClaudeAI.Log("Got government info from UI: gov=" .. tostring(result.currentGovernment) .. ", " .. slotCount .. " slots, " .. policyCount .. " policies available")
                else
                    ClaudeAI.Log("Failed to decode government info JSON from UI context")
                end
            else
                ClaudeAI.Log("No government info available from UI context")
            end
        else
            ClaudeAI.Log("No government info available from UI context (ExposedMembers)")
        end
    end)
    return result
end

-- Set turn-specific tactical notes
function ClaudeAI.SetTacticalNotes(notes)
    local success = false
    pcall(function()
        if Game and Game.SetProperty then
            Game.SetProperty(PROPERTY_KEYS.TACTICAL_NOTES, notes or "")
            success = true
        end
    end)
    return success
end

-- Clear tactical notes (called at end of turn)
function ClaudeAI.ClearTacticalNotes()
    ClaudeAI.SetTacticalNotes("")
end

-- JSON encoder for Lua tables (Civ6 doesn't have built-in JSON)
function ClaudeAI.TableToJSON(tbl, indent)
    indent = indent or 0

    if type(tbl) ~= "table" then
        if type(tbl) == "string" then
            return '"' .. ClaudeAI.EscapeString(tbl) .. '"'
        elseif type(tbl) == "boolean" then
            return tbl and "true" or "false"
        elseif tbl == nil then
            return "null"
        else
            return tostring(tbl)
        end
    end

    -- Check if array or object
    local isArray = #tbl > 0 or next(tbl) == nil
    local i = 1
    for k, v in pairs(tbl) do
        if k ~= i then
            isArray = false
            break
        end
        i = i + 1
    end

    local result = {}
    if isArray then
        table.insert(result, "[")
        local items = {}
        for _, v in ipairs(tbl) do
            table.insert(items, ClaudeAI.TableToJSON(v, indent + 1))
        end
        table.insert(result, table.concat(items, ","))
        table.insert(result, "]")
    else
        table.insert(result, "{")
        local items = {}
        for k, v in pairs(tbl) do
            local key = type(k) == "string" and k or tostring(k)
            table.insert(items, '"' .. key .. '":' .. ClaudeAI.TableToJSON(v, indent + 1))
        end
        table.insert(result, table.concat(items, ","))
        table.insert(result, "}")
    end

    return table.concat(result)
end

function ClaudeAI.EscapeString(str)
    if str == nil then return "" end
    str = string.gsub(str, '\\', '\\\\')
    str = string.gsub(str, '"', '\\"')
    str = string.gsub(str, '\n', '\\n')
    str = string.gsub(str, '\r', '\\r')
    str = string.gsub(str, '\t', '\\t')
    return str
end

-- Simple JSON decoder for a single action object
function ClaudeAI.DecodeSingleAction(jsonStr)
    -- Basic JSON parsing for a single action object
    if not jsonStr or jsonStr == "" then return nil end

    local result = {}

    -- Extract action field
    local action = jsonStr:match('"action"%s*:%s*"([^"]+)"')
    if action then
        result.action = action
    end

    -- Extract common fields
    result.unit_id = tonumber(jsonStr:match('"unit_id"%s*:%s*(%d+)'))
    result.city_id = tonumber(jsonStr:match('"city_id"%s*:%s*(%d+)'))
    result.x = tonumber(jsonStr:match('"x"%s*:%s*(-?%d+)'))
    result.y = tonumber(jsonStr:match('"y"%s*:%s*(-?%d+)'))
    result.target_x = tonumber(jsonStr:match('"target_x"%s*:%s*(-?%d+)'))
    result.target_y = tonumber(jsonStr:match('"target_y"%s*:%s*(-?%d+)'))
    result.item = jsonStr:match('"item"%s*:%s*"([^"]+)"')
    result.tech = jsonStr:match('"tech"%s*:%s*"([^"]+)"')
    result.civic = jsonStr:match('"civic"%s*:%s*"([^"]+)"')
    result.government = jsonStr:match('"government"%s*:%s*"([^"]+)"')
    result.reason = jsonStr:match('"reason"%s*:%s*"([^"]+)"')
    result.error = jsonStr:match('"error"%s*:%s*"([^"]+)"')

    -- Strategy and tactical notes (can contain escaped characters)
    result.strategy_notes = jsonStr:match('"strategy_notes"%s*:%s*"([^"]*)"')
    result.tactical_notes = jsonStr:match('"tactical_notes"%s*:%s*"([^"]*)"')

    -- Handle escaped characters in notes
    if result.strategy_notes then
        result.strategy_notes = result.strategy_notes:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"')
    end
    if result.tactical_notes then
        result.tactical_notes = result.tactical_notes:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"')
    end

    -- Parse policies object: {"0": "POLICY_NAME", "1": "POLICY_NAME", ...}
    local policiesStart = jsonStr:find('"policies"%s*:%s*{')
    if policiesStart then
        result.policies = {}
        local policiesEnd = jsonStr:find('}', policiesStart)
        if policiesEnd then
            local policiesStr = jsonStr:sub(policiesStart, policiesEnd)
            -- Extract each slot:policy pair
            for slotIndex, policyName in policiesStr:gmatch('"(%d+)"%s*:%s*"([^"]+)"') do
                result.policies[tonumber(slotIndex)] = policyName
            end
        end
    end

    return result
end

-- Decode JSON response with actions array
-- Returns a table with an "actions" array, or falls back to single action format
function ClaudeAI.DecodeJSON(jsonStr)
    if not jsonStr or jsonStr == "" then return nil end

    local result = { actions = {} }

    ClaudeAI.Log("DEBUG DecodeJSON: input length = " .. #jsonStr)
    ClaudeAI.Log("DEBUG DecodeJSON: first 200 chars = " .. jsonStr:sub(1, 200))

    -- Check if response has an "actions" array
    local actionsArrayStart = jsonStr:find('"actions"%s*:%s*%[')
    ClaudeAI.Log("DEBUG DecodeJSON: actionsArrayStart = " .. tostring(actionsArrayStart))
    if actionsArrayStart then
        -- Find the array content between [ and ]
        local arrayStart = jsonStr:find('%[', actionsArrayStart)
        if arrayStart then
            -- Find matching closing bracket (handle nested objects)
            local depth = 0
            local arrayEnd = nil
            for i = arrayStart, #jsonStr do
                local char = jsonStr:sub(i, i)
                if char == '[' then
                    depth = depth + 1
                elseif char == ']' then
                    depth = depth - 1
                    if depth == 0 then
                        arrayEnd = i
                        break
                    end
                end
            end

            ClaudeAI.Log("DEBUG DecodeJSON: arrayStart = " .. tostring(arrayStart) .. ", arrayEnd = " .. tostring(arrayEnd))
            if arrayEnd then
                local arrayContent = jsonStr:sub(arrayStart + 1, arrayEnd - 1)
                ClaudeAI.Log("DEBUG DecodeJSON: arrayContent length = " .. #arrayContent)
                ClaudeAI.Log("DEBUG DecodeJSON: arrayContent first 300 = " .. arrayContent:sub(1, 300))

                -- Split array into individual action objects
                -- Find each {...} object in the array
                local objStart = 1
                local actionCount = 0
                while true do
                    local objBegin = arrayContent:find('{', objStart)
                    if not objBegin then
                        ClaudeAI.Log("DEBUG DecodeJSON: No more { found after position " .. objStart)
                        break
                    end

                    -- Find matching closing brace (accounting for quoted strings)
                    local braceDepth = 0
                    local objEnd = nil
                    local inString = false
                    local prevChar = ""
                    for i = objBegin, #arrayContent do
                        local char = arrayContent:sub(i, i)
                        -- Track if we're inside a string (skip escaped quotes)
                        if char == '"' and prevChar ~= '\\' then
                            inString = not inString
                        elseif not inString then
                            if char == '{' then
                                braceDepth = braceDepth + 1
                            elseif char == '}' then
                                braceDepth = braceDepth - 1
                                if braceDepth == 0 then
                                    objEnd = i
                                    break
                                end
                            end
                        end
                        prevChar = char
                    end

                    if objEnd then
                        local actionJson = arrayContent:sub(objBegin, objEnd)
                        actionCount = actionCount + 1
                        ClaudeAI.Log("DEBUG DecodeJSON: Found action #" .. actionCount .. " from " .. objBegin .. " to " .. objEnd)
                        ClaudeAI.Log("DEBUG DecodeJSON: actionJson = " .. actionJson:sub(1, 100))
                        local action = ClaudeAI.DecodeSingleAction(actionJson)
                        if action and action.action then
                            table.insert(result.actions, action)
                            ClaudeAI.Log("DEBUG DecodeJSON: Decoded action type = " .. action.action)
                        else
                            ClaudeAI.Log("DEBUG DecodeJSON: Failed to decode action or no action field")
                        end
                        objStart = objEnd + 1
                    else
                        ClaudeAI.Log("DEBUG DecodeJSON: Could not find matching } for { at position " .. objBegin)
                        break
                    end
                end
            else
                ClaudeAI.Log("DEBUG DecodeJSON: arrayEnd is nil")
            end
        end

        ClaudeAI.Log("Decoded " .. #result.actions .. " actions from array")
        return result
    end

    -- Fallback: Check for single action format (legacy support)
    local singleAction = ClaudeAI.DecodeSingleAction(jsonStr)
    if singleAction and singleAction.action then
        result.actions = { singleAction }
        ClaudeAI.Log("Decoded single action (legacy format)")
        return result
    end

    -- Check for error
    local error = jsonStr:match('"error"%s*:%s*"([^"]+)"')
    if error then
        result.error = error
        ClaudeAI.Log("Decoded error response: " .. error)
        return result
    end

    ClaudeAI.Log("WARNING: Could not decode JSON response")
    return nil
end

-- ============================================================================
-- GAME INFO HELPERS (used by unit/city serialization)
-- Note: Terrain/Feature/Resource name helpers are in TERRAIN SERIALIZATION section
-- ============================================================================

function ClaudeAI.GetUnitName(unitType)
    if unitType == -1 then return nil end
    local info = GameInfo.Units[unitType]
    return info and info.UnitType or nil
end

function ClaudeAI.GetBuildingName(buildingType)
    if buildingType == -1 then return nil end
    local info = GameInfo.Buildings[buildingType]
    return info and info.BuildingType or nil
end

function ClaudeAI.GetDistrictName(districtType)
    if districtType == -1 then return nil end
    local info = GameInfo.Districts[districtType]
    return info and info.DistrictType or nil
end

function ClaudeAI.GetTechName(techType)
    if techType == -1 then return nil end
    if not GameInfo or not GameInfo.Technologies then return nil end
    local info = GameInfo.Technologies[techType]
    return info and info.TechnologyType or nil
end

function ClaudeAI.GetCivicName(civicType)
    if civicType == -1 then return nil end
    if not GameInfo or not GameInfo.Civics then return nil end
    local info = GameInfo.Civics[civicType]
    return info and info.CivicType or nil
end

-- ============================================================================
-- UNIT SERIALIZATION
-- ============================================================================

function ClaudeAI.SerializeUnit(pUnit)
    if not pUnit then return nil end

    local result = {}
    local success, err = pcall(function()
        local unitType = pUnit:GetType()
        local unitInfo = GameInfo.Units[unitType]
        local unitTypeName = ClaudeAI.GetUnitName(unitType)

        -- Get values using SafeGet helper (protects against "Not Implemented" errors)
        local unitName = SafeGet(pUnit, "GetName") or "Unknown"
        local maxDamage = SafeGet(pUnit, "GetMaxDamage") or 100
        local damage = SafeGet(pUnit, "GetDamage") or 0
        local movesRemaining = SafeGet(pUnit, "GetMovesRemaining") or 0
        local maxMoves = SafeGet(pUnit, "GetMaxMoves") or 0
        local combat = SafeGet(pUnit, "GetCombat") or 0
        local rangedCombat = SafeGet(pUnit, "GetRangedCombat") or 0
        local range = SafeGet(pUnit, "GetRange") or 0
        local charges = SafeGet(pUnit, "GetBuildCharges") or 0  -- Can throw "Not Implemented" for non-builder units

        -- Check if this is a settler and can found city at current location
        local isSettler = unitTypeName == "Settler" or (unitInfo and unitInfo.FoundCity)
        local canFoundCity = false
        local canFoundCityHere = false

        if isSettler then
            canFoundCity = true
            -- Check if current location is valid for founding
            local unitX, unitY = pUnit:GetX(), pUnit:GetY()
            local pPlot = Map.GetPlot(unitX, unitY)
            if pPlot then
                -- Basic checks for valid founding location
                local isValidTerrain = not pPlot:IsWater() and not pPlot:IsMountain()
                local noExistingCity = not pPlot:IsCity()
                -- Check minimum distance to other cities (usually 3 tiles)
                local tooCloseToCity = false
                pcall(function()
                    -- Check nearby plots for cities
                    for dx = -3, 3 do
                        for dy = -3, 3 do
                            local nearPlot = Map.GetPlot(unitX + dx, unitY + dy)
                            if nearPlot and nearPlot:IsCity() then
                                tooCloseToCity = true
                            end
                        end
                    end
                end)
                canFoundCityHere = isValidTerrain and noExistingCity and not tooCloseToCity and movesRemaining > 0
            end
        end

        result = {
            id = pUnit:GetID(),
            type = unitTypeName,
            name = unitName,
            x = pUnit:GetX(),
            y = pUnit:GetY(),
            health = maxDamage - damage,
            maxHealth = maxDamage,
            moves = movesRemaining,
            maxMoves = maxMoves,
            combat = combat,
            rangedCombat = rangedCombat,
            range = range,
            charges = charges,
            canMove = movesRemaining > 0,
            isCivilian = unitInfo and unitInfo.FormationClass == "FORMATION_CLASS_CIVILIAN" or false,
            isSettler = isSettler,
            canFoundCity = canFoundCity,
            canFoundCityHere = canFoundCityHere,  -- Can found at CURRENT location this turn
        }

        -- Add builder-specific info if this unit has build charges (is a builder)
        local isBuilder = charges > 0 and (unitTypeName == "UNIT_BUILDER" or (unitInfo and unitInfo.BuildCharges and unitInfo.BuildCharges > 0))
        if isBuilder then
            result.isBuilder = true
            -- Get available actions at current location
            local builderActions = ClaudeAI.GetBuilderActions(pUnit, pUnit:GetOwner())
            if builderActions then
                result.availableImprovements = builderActions.availableImprovements
                result.canHarvest = builderActions.canHarvest
                result.harvestType = builderActions.harvestType
                result.canRemoveFeature = builderActions.canRemoveFeature
                result.featureType = builderActions.featureType
                result.canRepair = builderActions.canRepair
            end
        end

        -- Add trader-specific info if this is a trader unit
        if unitTypeName == "UNIT_TRADER" then
            result.isTrader = true
            -- Get available trade route destinations
            local destinations = ClaudeAI.GetTradeRouteDestinations(pUnit, pUnit:GetOwner())
            if destinations and #destinations > 0 then
                result.tradeDestinations = destinations
            end
        end

        -- Add upgrade info for military units
        if combat > 0 or rangedCombat > 0 then
            local upgradeInfo = ClaudeAI.GetUnitUpgradeInfo(pUnit, pUnit:GetOwner())
            if upgradeInfo and upgradeInfo.canUpgrade then
                result.canUpgrade = true
                result.upgradeType = upgradeInfo.upgradeType
                result.upgradeCost = upgradeInfo.cost
            end

            -- Add promotion info
            local promotionInfo = ClaudeAI.GetUnitPromotionInfo(pUnit)
            if promotionInfo then
                if promotionInfo.canPromote then
                    result.canPromote = true
                    result.availablePromotions = promotionInfo.availablePromotions
                end
                if promotionInfo.currentPromotions and #promotionInfo.currentPromotions > 0 then
                    result.promotions = promotionInfo.currentPromotions
                end
                result.experience = promotionInfo.experience
                result.level = promotionInfo.level
            end
        end
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error serializing unit: " .. tostring(err))
        -- Return minimal info on error
        return {
            id = pUnit:GetID(),
            x = pUnit:GetX(),
            y = pUnit:GetY(),
            type = "Unknown",
            name = "Unknown",
        }
    end

    return result
end

function ClaudeAI.SerializeEnemyUnit(pUnit)
    if not pUnit then return nil end

    local result = {}
    local success, err = pcall(function()
        -- Get health/combat values using SafeGet helper
        local maxDamage = SafeGet(pUnit, "GetMaxDamage") or 100
        local damage = SafeGet(pUnit, "GetDamage") or 0
        local combat = SafeGet(pUnit, "GetCombat") or 0
        local rangedCombat = SafeGet(pUnit, "GetRangedCombat") or 0

        -- Get owner civilization name
        local ownerID = pUnit:GetOwner()
        local ownerCiv = "Unknown"
        local pOwner = Players[ownerID]
        if pOwner then
            local civTypeID = SafeGet(pOwner, "GetCivilizationType")
            local civInfo = FindGameInfoByIndex(GameInfo.Civilizations, civTypeID)
            if civInfo and civInfo.CivilizationType then
                ownerCiv = civInfo.CivilizationType
                if ownerCiv:find("CIVILIZATION_") == 1 then
                    ownerCiv = ownerCiv:sub(14)  -- Remove "CIVILIZATION_" prefix
                end
            end
        end

        result = {
            id = pUnit:GetID(),  -- Include ID for targeting with attack action
            type = ClaudeAI.GetUnitName(pUnit:GetType()),
            owner = ownerID,
            ownerCiv = ownerCiv,
            x = pUnit:GetX(),
            y = pUnit:GetY(),
            health = maxDamage - damage,
            maxHealth = maxDamage,
            combat = combat,
            rangedCombat = rangedCombat,
        }
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error serializing enemy unit: " .. tostring(err))
        -- Return minimal info on error
        return {
            x = pUnit:GetX(),
            y = pUnit:GetY(),
            owner = pUnit:GetOwner(),
            type = "Unknown",
        }
    end

    return result
end

-- ============================================================================
-- TERRAIN SERIALIZATION
-- ============================================================================

-- Helper to get terrain name from type (uses local GetTypeNameByIndex helper)
function ClaudeAI.GetTerrainName(terrainType)
    return GetTypeNameByIndex(GameInfo.Terrains, terrainType, "TerrainType", "TERRAIN_") or "Unknown"
end

-- Helper to get feature name from type
function ClaudeAI.GetFeatureName(featureType)
    if featureType == nil or featureType < 0 then return nil end
    return GetTypeNameByIndex(GameInfo.Features, featureType, "FeatureType", "FEATURE_")
end

-- Helper to get resource name from type
function ClaudeAI.GetResourceName(resourceType)
    if resourceType == nil or resourceType < 0 then return nil end
    return GetTypeNameByIndex(GameInfo.Resources, resourceType, "ResourceType", "RESOURCE_")
end

-- Helper to get improvement name from type
function ClaudeAI.GetImprovementName(improvementType)
    if improvementType == nil or improvementType < 0 then return nil end
    return GetTypeNameByIndex(GameInfo.Improvements, improvementType, "ImprovementType", "IMPROVEMENT_")
end

-- Serialize a single plot
function ClaudeAI.SerializePlot(pPlot, playerID)
    if not pPlot then return nil end

    local result = {}
    local success, err = pcall(function()
        local x = pPlot:GetX()
        local y = pPlot:GetY()

        -- Basic terrain info
        local terrainType = pPlot:GetTerrainType()
        local featureType = pPlot:GetFeatureType()
        local resourceType = pPlot:GetResourceType()

        -- Get all yields using SafeCall
        local yieldFood = GameInfo.Yields and GameInfo.Yields["YIELD_FOOD"]
        local yieldProd = GameInfo.Yields and GameInfo.Yields["YIELD_PRODUCTION"]
        local yieldGold = GameInfo.Yields and GameInfo.Yields["YIELD_GOLD"]
        local yieldScience = GameInfo.Yields and GameInfo.Yields["YIELD_SCIENCE"]
        local yieldCulture = GameInfo.Yields and GameInfo.Yields["YIELD_CULTURE"]
        local yieldFaith = GameInfo.Yields and GameInfo.Yields["YIELD_FAITH"]

        local food = yieldFood and SafeGet(pPlot, "GetYield", yieldFood.Index) or 0
        local production = yieldProd and SafeGet(pPlot, "GetYield", yieldProd.Index) or 0
        local gold = yieldGold and SafeGet(pPlot, "GetYield", yieldGold.Index) or 0
        local science = yieldScience and SafeGet(pPlot, "GetYield", yieldScience.Index) or 0
        local culture = yieldCulture and SafeGet(pPlot, "GetYield", yieldCulture.Index) or 0
        local faith = yieldFaith and SafeGet(pPlot, "GetYield", yieldFaith.Index) or 0

        -- Check for improvements using the helper
        local improvementType = pPlot:GetImprovementType()
        local improvement = ClaudeAI.GetImprovementName(improvementType)

        local plotIsWater = pPlot:IsWater()
        local plotIsOcean = false
        if plotIsWater and pPlot.IsShallowWater then
            plotIsOcean = not pPlot:IsShallowWater()
        end

        result = {
            x = x,
            y = y,
            terrain = ClaudeAI.GetTerrainName(terrainType),
            feature = ClaudeAI.GetFeatureName(featureType),
            resource = ClaudeAI.GetResourceName(resourceType),
            improvement = improvement,
            isWater = plotIsWater,
            isOcean = plotIsOcean,  -- true = deep ocean (needs Cartography), false = coast or land
            isMountain = pPlot:IsMountain(),
            isHills = pPlot:IsHills(),
            hasCity = pPlot:IsCity(),
            yields = {
                food = food,
                production = production,
                gold = gold,
                science = science,
                culture = culture,
                faith = faith,
            },
        }
    end)

    if not success then
        return nil
    end

    return result
end

-- Get visible terrain around all units (within a certain radius)
function ClaudeAI.GetVisibleTerrain(playerID, radius)
    radius = radius or 3  -- Default 3 tile radius around units

    local visiblePlots = {}
    local seenPlots = {}  -- Track already serialized plots to avoid duplicates
    local pPlayer = Players[playerID]

    if not pPlayer then return visiblePlots end

    local pVisibility = PlayersVisibility[playerID]

    -- Get terrain around each unit
    local pUnits = pPlayer:GetUnits()
    if pUnits and pUnits.Members then
        for _, pUnit in pUnits:Members() do
            local unitX = pUnit:GetX()
            local unitY = pUnit:GetY()

            for dx = -radius, radius do
                for dy = -radius, radius do
                    local plotX = unitX + dx
                    local plotY = unitY + dy
                    local plotKey = plotX .. "," .. plotY

                    if not seenPlots[plotKey] then
                        local pPlot = Map.GetPlot(plotX, plotY)
                        if pPlot then
                            -- Check if plot is visible to player
                            local isVisible = true
                            if pVisibility then
                                pcall(function()
                                    isVisible = pVisibility:IsVisible(plotX, plotY) or pVisibility:IsRevealed(plotX, plotY)
                                end)
                            end

                            if isVisible then
                                local plotData = ClaudeAI.SerializePlot(pPlot, playerID)
                                if plotData then
                                    table.insert(visiblePlots, plotData)
                                    seenPlots[plotKey] = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Also get terrain around cities
    local pCities = pPlayer:GetCities()
    if pCities and pCities.Members then
        for _, pCity in pCities:Members() do
            local cityX = pCity:GetX()
            local cityY = pCity:GetY()

            for dx = -radius, radius do
                for dy = -radius, radius do
                    local plotX = cityX + dx
                    local plotY = cityY + dy
                    local plotKey = plotX .. "," .. plotY

                    if not seenPlots[plotKey] then
                        local pPlot = Map.GetPlot(plotX, plotY)
                        if pPlot then
                            local plotData = ClaudeAI.SerializePlot(pPlot, playerID)
                            if plotData then
                                table.insert(visiblePlots, plotData)
                                seenPlots[plotKey] = true
                            end
                        end
                    end
                end
            end
        end
    end

    return visiblePlots
end

-- ============================================================================
-- CITY SERIALIZATION
-- ============================================================================

function ClaudeAI.SerializeCity(pCity, playerID)
    if not pCity then return nil end

    local result = {}
    local success, err = pcall(function()
        local currentProduction = nil
        local turnsLeft = nil

        -- Get build queue info with extra protection
        -- Some methods exist but throw "Not Implemented" errors
        pcall(function()
            local pBuildQueue = pCity:GetBuildQueue()
            if pBuildQueue then
                pcall(function()
                    local building = pBuildQueue:CurrentlyBuilding()
                    if building and building ~= "NO_PRODUCTION" then
                        currentProduction = building
                    end
                end)
                -- GetTurnsLeft can throw "Not Implemented" even when the method exists
                pcall(function()
                    if currentProduction then
                        turnsLeft = pBuildQueue:GetTurnsLeft()
                    end
                end)
            end
        end)

        -- Get basic city info using SafeGet helper
        local cityName = SafeGet(pCity, "GetName") or "Unknown"
        local population = SafeGet(pCity, "GetPopulation") or 0
        local isCapital = SafeGet(pCity, "IsCapital") or false

        -- Get production yields for fallback calculation
        local productionPerTurn = SafeGet(pCity, "GetYield", YieldTypes.PRODUCTION) or 0

        -- Fallback: calculate turns left if API didn't return it
        if currentProduction and (not turnsLeft or turnsLeft == 0) and productionPerTurn > 0 then
            pcall(function()
                local pBuildQueue = pCity:GetBuildQueue()
                if pBuildQueue then
                    local progress = 0
                    local cost = 0

                    -- Try to get current progress
                    if pBuildQueue.GetProductionProgress then
                        progress = pBuildQueue:GetProductionProgress() or 0
                    end

                    -- Try to get cost of current item
                    if pBuildQueue.GetProductionCost then
                        cost = pBuildQueue:GetProductionCost() or 0
                    end

                    if cost > 0 and productionPerTurn > 0 then
                        local remaining = cost - progress
                        if remaining > 0 then
                            turnsLeft = math.ceil(remaining / productionPerTurn)
                        else
                            turnsLeft = 1  -- Almost done
                        end
                    end
                end
            end)
        end

        result = {
            id = pCity:GetID(),
            name = cityName,
            x = pCity:GetX(),
            y = pCity:GetY(),
            population = population,
            isCapital = isCapital,
            production = currentProduction,
            turnsLeft = turnsLeft,
            productionPerTurn = productionPerTurn,  -- Add this so Claude knows city output
        }

        -- Debug logging for city production
        if currentProduction then
            ClaudeAI.Log("DEBUG: City " .. cityName .. " producing " .. tostring(currentProduction) .. " turnsLeft=" .. tostring(turnsLeft) .. " (prod/turn=" .. tostring(productionPerTurn) .. ")")
        end

        -- Add buildable items (only if city has no current production or we want to show options)
        local buildables = ClaudeAI.GetCityBuildables(pCity, playerID)
        if buildables then
            result.canBuild = buildables
        end

        -- Add purchasable items (with gold/faith)
        local purchasable = ClaudeAI.GetPurchasableItems(pCity, playerID)
        if purchasable then
            -- Only include non-empty lists
            if purchasable.goldUnits and #purchasable.goldUnits > 0 then
                result.canPurchaseGold = {
                    units = purchasable.goldUnits,
                    buildings = purchasable.goldBuildings,
                }
            end
            if purchasable.faithUnits and #purchasable.faithUnits > 0 then
                result.canPurchaseFaith = {
                    units = purchasable.faithUnits,
                    buildings = purchasable.faithBuildings,
                }
            end
        end

        -- Add city combat info (for ranged attacks)
        local combatInfo = ClaudeAI.GetCityCombatInfo(pCity, playerID)
        if combatInfo and combatInfo.canAttack then
            result.canAttack = true
            result.rangedStrength = combatInfo.rangedStrength
            if combatInfo.targets and #combatInfo.targets > 0 then
                result.attackTargets = combatInfo.targets
            end
        end

        -- Add district placement options for available districts
        -- Only include for districts the city can build
        if buildables and buildables.districts and #buildables.districts > 0 then
            result.districtPlacements = {}
            for _, districtEntry in ipairs(buildables.districts) do
                local districtType = districtEntry.type
                local placements = ClaudeAI.GetDistrictPlacements(pCity, districtType, playerID)
                if placements and #placements > 0 then
                    -- Include top 5 placements to keep JSON size manageable
                    local topPlacements = {}
                    for i = 1, math.min(5, #placements) do
                        table.insert(topPlacements, placements[i])
                    end
                    result.districtPlacements[districtType] = topPlacements
                end
            end
        end
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error serializing city: " .. tostring(err))
        -- Return minimal info even on error
        return {
            id = pCity:GetID(),
            x = pCity:GetX(),
            y = pCity:GetY(),
            name = "Unknown",
            population = 0,
        }
    end

    return result
end

-- Check if player meets tech prerequisite
function ClaudeAI.HasTechPrereq(playerID, prereqTech)
    if not prereqTech then return true end  -- No prereq = always available

    local pPlayer = Players[playerID]
    if not pPlayer then return false end

    local hasTech = false
    pcall(function()
        local pTechs = pPlayer:GetTechs()
        if pTechs and pTechs.HasTech then
            local techInfo = GameInfo.Technologies[prereqTech]
            if techInfo then
                hasTech = pTechs:HasTech(techInfo.Index)
            end
        end
    end)
    return hasTech
end

-- Check if player meets civic prerequisite
function ClaudeAI.HasCivicPrereq(playerID, prereqCivic)
    if not prereqCivic then return true end  -- No prereq = always available

    local pPlayer = Players[playerID]
    if not pPlayer then return false end

    local hasCivic = false
    pcall(function()
        local pCulture = pPlayer:GetCulture()
        if pCulture and pCulture.HasCivic then
            local civicInfo = GameInfo.Civics[prereqCivic]
            if civicInfo then
                hasCivic = pCulture:HasCivic(civicInfo.Index)
            end
        end
    end)
    return hasCivic
end

-- Check if player has a strategic resource
function ClaudeAI.HasStrategicResource(playerID, resourceType)
    if not resourceType then return true end  -- No resource requirement

    local pPlayer = Players[playerID]
    if not pPlayer then return false end

    local hasResource = false
    pcall(function()
        local pResources = pPlayer:GetResources()
        if pResources then
            local resourceInfo = GameInfo.Resources[resourceType]
            if resourceInfo then
                -- GetResourceAmount returns how many of that resource the player has
                local amount = pResources:GetResourceAmount(resourceInfo.Index)
                hasResource = amount and amount > 0
            end
        end
    end)
    return hasResource
end

-- Check if city has a specific district
function ClaudeAI.CityHasDistrict(pCity, districtType)
    if not districtType then return true end  -- No district requirement

    local hasDistrict = false
    pcall(function()
        local pDistricts = pCity:GetDistricts()
        if pDistricts then
            local districtInfo = GameInfo.Districts[districtType]
            if districtInfo then
                hasDistrict = pDistricts:HasDistrict(districtInfo.Index)
            end
        end
    end)
    return hasDistrict
end

-- Calculate adjacency bonus for a district at a specific plot
function ClaudeAI.CalculateDistrictAdjacency(pPlot, districtType, playerID)
    if not pPlot or not districtType then return 0, {} end

    local totalBonus = 0
    local bonusSources = {}

    local success, err = pcall(function()
        local plotX, plotY = pPlot:GetX(), pPlot:GetY()
        local districtInfo = GameInfo.Districts[districtType]
        if not districtInfo then return end

        -- Get adjacency rules for this district
        if GameInfo.District_Adjacencies then
            for adjRow in GameInfo.District_Adjacencies() do
                if adjRow.DistrictType == districtType then
                    local yieldChange = adjRow.YieldChange or 0
                    local tilesRequired = adjRow.TilesRequired or 1

                    -- Check each adjacent tile (6 neighbors in hex grid)
                    local adjacentCount = 0
                    local directions = {
                        {0, 1}, {1, 0}, {1, -1}, {0, -1}, {-1, 0}, {-1, 1}
                    }

                    for _, dir in ipairs(directions) do
                        local adjX = plotX + dir[1]
                        local adjY = plotY + dir[2]
                        local adjPlot = Map.GetPlot(adjX, adjY)

                        if adjPlot then
                            local matches = false

                            -- Check what this adjacency bonus requires
                            if adjRow.AdjacentDistrict then
                                -- Adjacent district bonus
                                local adjDistrictType = adjPlot:GetDistrictType()
                                if adjDistrictType >= 0 then
                                    local adjDistrictInfo = GameInfo.Districts[adjDistrictType]
                                    if adjDistrictInfo and adjDistrictInfo.DistrictType == adjRow.AdjacentDistrict then
                                        matches = true
                                    end
                                end
                            elseif adjRow.AdjacentTerrain then
                                -- Adjacent terrain bonus (e.g., mountain for campus)
                                local terrainType = adjPlot:GetTerrainType()
                                local terrainInfo = GameInfo.Terrains[terrainType]
                                if terrainInfo and terrainInfo.TerrainType == adjRow.AdjacentTerrain then
                                    matches = true
                                end
                            elseif adjRow.AdjacentFeature then
                                -- Adjacent feature bonus (e.g., rainforest for campus)
                                local featureType = adjPlot:GetFeatureType()
                                if featureType >= 0 then
                                    local featureInfo = GameInfo.Features[featureType]
                                    if featureInfo and featureInfo.FeatureType == adjRow.AdjacentFeature then
                                        matches = true
                                    end
                                end
                            elseif adjRow.AdjacentResource then
                                -- Adjacent resource bonus
                                local resourceType = adjPlot:GetResourceType()
                                if resourceType >= 0 then
                                    local resourceInfo = GameInfo.Resources[resourceType]
                                    if resourceInfo and resourceInfo.ResourceType == adjRow.AdjacentResource then
                                        matches = true
                                    end
                                end
                            elseif adjRow.AdjacentNaturalWonder then
                                -- Natural wonder bonus
                                local featureType = adjPlot:GetFeatureType()
                                if featureType >= 0 then
                                    local featureInfo = GameInfo.Features[featureType]
                                    if featureInfo and featureInfo.NaturalWonder then
                                        matches = true
                                    end
                                end
                            end

                            if matches then
                                adjacentCount = adjacentCount + 1
                            end
                        end
                    end

                    -- Calculate bonus based on tiles required
                    if adjacentCount >= tilesRequired then
                        local bonusFromThis = math.floor(adjacentCount / tilesRequired) * yieldChange
                        if bonusFromThis > 0 then
                            totalBonus = totalBonus + bonusFromThis
                            local sourceDesc = adjRow.AdjacentDistrict or adjRow.AdjacentTerrain or adjRow.AdjacentFeature or "unknown"
                            table.insert(bonusSources, {source = sourceDesc, bonus = bonusFromThis})
                        end
                    end
                end
            end
        end
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error calculating adjacency: " .. tostring(err))
    end

    return totalBonus, bonusSources
end

-- Get valid district placement locations for a city
function ClaudeAI.GetDistrictPlacements(pCity, districtType, playerID)
    local placements = {}

    if not pCity or not districtType then return placements end

    local success, err = pcall(function()
        local cityX, cityY = pCity:GetX(), pCity:GetY()
        local pPlayer = Players[playerID]

        -- Get city's workable tiles (3-tile radius)
        for dx = -3, 3 do
            for dy = -3, 3 do
                local plotX = cityX + dx
                local plotY = cityY + dy
                local pPlot = Map.GetPlot(plotX, plotY)

                if pPlot then
                    -- Check if this plot belongs to the city
                    local plotOwner = pPlot:GetOwner()
                    if plotOwner == playerID then
                        -- Check if plot is valid for district placement
                        local canPlace = true

                        -- Can't place on water (except Harbor)
                        if pPlot:IsWater() and districtType ~= "DISTRICT_HARBOR" then
                            canPlace = false
                        end

                        -- Can't place on mountains
                        if pPlot:IsMountain() then
                            canPlace = false
                        end

                        -- Can't place where there's already a district or city
                        if pPlot:GetDistrictType() >= 0 then
                            canPlace = false
                        end

                        -- Can't place on wonder tiles
                        local featureType = pPlot:GetFeatureType()
                        if featureType >= 0 then
                            local featureInfo = GameInfo.Features[featureType]
                            if featureInfo and featureInfo.NaturalWonder then
                                canPlace = false
                            end
                        end

                        if canPlace then
                            local adjacencyBonus, bonusSources = ClaudeAI.CalculateDistrictAdjacency(pPlot, districtType, playerID)

                            table.insert(placements, {
                                x = plotX,
                                y = plotY,
                                adjacencyBonus = adjacencyBonus,
                                bonusSources = bonusSources,
                                terrain = ClaudeAI.GetTerrainName(pPlot:GetTerrainType()),
                                feature = ClaudeAI.GetFeatureName(pPlot:GetFeatureType()),
                                isHills = pPlot:IsHills(),
                            })
                        end
                    end
                end
            end
        end

        -- Sort by adjacency bonus (highest first)
        table.sort(placements, function(a, b)
            return a.adjacencyBonus > b.adjacencyBonus
        end)
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error getting district placements: " .. tostring(err))
    end

    return placements
end

-- Check if city already has a building
function ClaudeAI.CityHasBuilding(pCity, buildingType)
    if not buildingType then return false end

    local hasBuilding = false
    pcall(function()
        local pBuildings = pCity:GetBuildings()
        if pBuildings then
            local buildingInfo = GameInfo.Buildings[buildingType]
            if buildingInfo then
                hasBuilding = pBuildings:HasBuilding(buildingInfo.Index)
            end
        end
    end)
    return hasBuilding
end

-- Get the strategic resource required for a unit (if any)
function ClaudeAI.GetUnitStrategicResource(unitType)
    local resource = nil
    pcall(function()
        if GameInfo.Units_XP2 then
            -- Gathering Storm uses Units_XP2 for resource costs
            for row in GameInfo.Units_XP2() do
                if row.UnitType == unitType and row.StrategicResource then
                    resource = row.StrategicResource
                    break
                end
            end
        end
        -- Also check base game resource requirements
        if not resource and GameInfo.Unit_ResourceRequirements then
            for row in GameInfo.Unit_ResourceRequirements() do
                if row.UnitType == unitType then
                    resource = row.ResourceType
                    break
                end
            end
        end
    end)
    return resource
end

-- Get buildable items for a city by checking all prerequisites
function ClaudeAI.GetCityBuildables(pCity, playerID)
    local buildables = {
        units = {},
        buildings = {},
        districts = {},
    }

    if not pCity then return buildables end

    local cityPopulation = 1
    pcall(function() cityPopulation = pCity:GetPopulation() end)

    -- Get all units the player can potentially build
    pcall(function()
        if GameInfo.Units then
            for row in GameInfo.Units() do
                -- Skip if it's a unique unit (has TraitType) - these are civ-specific
                local dominated = row.TraitType ~= nil

                if not dominated then
                    local hasTech = ClaudeAI.HasTechPrereq(playerID, row.PrereqTech)
                    local hasCivic = ClaudeAI.HasCivicPrereq(playerID, row.PrereqCivic)

                    -- Check strategic resource requirement
                    local strategicResource = ClaudeAI.GetUnitStrategicResource(row.UnitType)
                    local hasResource = ClaudeAI.HasStrategicResource(playerID, strategicResource)

                    -- Check population for settlers (need pop > 1 to build)
                    local canAffordPop = true
                    if row.UnitType == "UNIT_SETTLER" and cityPopulation <= 1 then
                        canAffordPop = false
                    end

                    if hasTech and hasCivic and hasResource and canAffordPop then
                        table.insert(buildables.units, {
                            type = row.UnitType,
                            cost = row.Cost,
                        })
                    end
                end
            end
        end
    end)

    -- Get all buildings (filter by all prereqs)
    pcall(function()
        if GameInfo.Buildings then
            for row in GameInfo.Buildings() do
                -- Skip wonders (IsWonder) and unique buildings (TraitType)
                local dominated = row.IsWonder or row.TraitType ~= nil

                if not dominated then
                    local hasTech = ClaudeAI.HasTechPrereq(playerID, row.PrereqTech)
                    local hasCivic = ClaudeAI.HasCivicPrereq(playerID, row.PrereqCivic)

                    -- Check if city has required district
                    local hasDistrict = ClaudeAI.CityHasDistrict(pCity, row.PrereqDistrict)

                    -- Check if city already has this building
                    local alreadyHas = ClaudeAI.CityHasBuilding(pCity, row.BuildingType)

                    if hasTech and hasCivic and hasDistrict and not alreadyHas then
                        table.insert(buildables.buildings, {
                            type = row.BuildingType,
                            cost = row.Cost,
                        })
                    end
                end
            end
        end
    end)

    -- Get all districts (filter by tech/civic prereqs and not already built)
    pcall(function()
        if GameInfo.Districts then
            for row in GameInfo.Districts() do
                -- Skip unique districts (TraitType) and special districts
                local dominated = row.TraitType ~= nil
                    or row.DistrictType == "DISTRICT_CITY_CENTER"
                    or row.DistrictType == "DISTRICT_WONDER"

                if not dominated then
                    local hasTech = ClaudeAI.HasTechPrereq(playerID, row.PrereqTech)
                    local hasCivic = ClaudeAI.HasCivicPrereq(playerID, row.PrereqCivic)

                    -- Check if city already has this district
                    local alreadyHas = ClaudeAI.CityHasDistrict(pCity, row.DistrictType)

                    -- Check population requirement for districts (1 district per 3 pop, roughly)
                    -- This is approximate - actual formula is more complex
                    local districtCount = 0
                    pcall(function()
                        local pDistricts = pCity:GetDistricts()
                        if pDistricts then
                            districtCount = pDistricts:GetNumDistricts()
                        end
                    end)
                    local canBuildMore = (cityPopulation >= districtCount * 3) or districtCount == 0

                    if hasTech and hasCivic and not alreadyHas and canBuildMore then
                        table.insert(buildables.districts, {
                            type = row.DistrictType,
                            cost = row.Cost,
                        })
                    end
                end
            end
        end
    end)

    -- Get wonders (only if prereqs met and not already built globally)
    buildables.wonders = {}
    pcall(function()
        if GameInfo.Buildings then
            for row in GameInfo.Buildings() do
                if row.IsWonder then
                    local hasTech = ClaudeAI.HasTechPrereq(playerID, row.PrereqTech)
                    local hasCivic = ClaudeAI.HasCivicPrereq(playerID, row.PrereqCivic)

                    -- Check if city has required district for wonder
                    local hasDistrict = ClaudeAI.CityHasDistrict(pCity, row.PrereqDistrict)

                    -- Check if wonder has already been built anywhere in the world
                    local alreadyBuilt = ClaudeAI.IsWonderBuilt(row.BuildingType)

                    if hasTech and hasCivic and hasDistrict and not alreadyBuilt then
                        table.insert(buildables.wonders, {
                            type = row.BuildingType,
                            cost = row.Cost,
                        })
                    end
                end
            end
        end
    end)

    return buildables
end

function ClaudeAI.SerializeEnemyCity(pCity)
    if not pCity then return nil end

    local result = {}
    local success, err = pcall(function()
        -- Get values using SafeGet helper
        local cityName = SafeGet(pCity, "GetName") or "Unknown"
        local population = SafeGet(pCity, "GetPopulation") or 0
        local isCapital = SafeGet(pCity, "IsCapital") or false

        result = {
            name = cityName,
            owner = pCity:GetOwner(),
            x = pCity:GetX(),
            y = pCity:GetY(),
            population = population,
            isCapital = isCapital,
        }
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error serializing enemy city: " .. tostring(err))
        -- Return minimal info on error
        return {
            x = pCity:GetX(),
            y = pCity:GetY(),
            owner = pCity:GetOwner(),
            name = "Unknown",
        }
    end

    return result
end

-- ============================================================================
-- PLAYER STATE SERIALIZATION
-- ============================================================================

function ClaudeAI.SerializePlayerState(playerID)
    local pPlayer = Players[playerID]
    if not pPlayer then return nil end

    local result = {}
    local success, err = pcall(function()
        local pTreasury = pPlayer.GetTreasury and pPlayer:GetTreasury()
        local pReligion = pPlayer.GetReligion and pPlayer:GetReligion()
        local pTechs = pPlayer.GetTechs and pPlayer:GetTechs()
        local pCulture = pPlayer.GetCulture and pPlayer:GetCulture()

        -- Calculate yields FIRST so we can use them for turns remaining calculations
        local gold = 0
        local goldPerTurn = 0
        local faith = 0
        local faithPerTurn = 0
        local sciencePerTurn = 0
        local culturePerTurn = 0

        if pTreasury then
            pcall(function()
                if pTreasury.GetGoldBalance then gold = pTreasury:GetGoldBalance() end
            end)
            pcall(function()
                if pTreasury.GetGoldYield and pTreasury.GetTotalMaintenance then
                    goldPerTurn = pTreasury:GetGoldYield() - pTreasury:GetTotalMaintenance()
                end
            end)
        end

        if pReligion then
            pcall(function()
                if pReligion.GetFaithBalance then faith = pReligion:GetFaithBalance() end
            end)
            pcall(function()
                if pReligion.GetFaithYield then faithPerTurn = pReligion:GetFaithYield() end
            end)
        end

        pcall(function()
            if pTechs and pTechs.GetScienceYield then
                sciencePerTurn = pTechs:GetScienceYield()
            end
        end)

        -- GetCultureYield is UI-only, calculate from city yields instead
        pcall(function()
            local pCities = pPlayer:GetCities()
            if pCities and pCities.Members then
                for _, pCity in pCities:Members() do
                    local cityYields = pCity:GetYields()
                    if cityYields and cityYields.GetYield then
                        -- YieldTypes.CULTURE = 5 in Civ6
                        local cityCulture = cityYields:GetYield(5) or 0
                        culturePerTurn = culturePerTurn + cityCulture
                    end
                end
            end
        end)

        -- Fallback for early game (before city founded) - estimate at least 1 yield
        if sciencePerTurn == 0 then sciencePerTurn = 1 end
        if culturePerTurn == 0 then culturePerTurn = 1 end

        -- Current research
        local currentTech = nil
        if pTechs and pTechs.GetResearchingTech then
            pcall(function()
                local researchingTech = pTechs:GetResearchingTech()
                if researchingTech and researchingTech ~= -1 then
                    local techName = ClaudeAI.GetTechName(researchingTech)
                    local turnsLeft = 0

                    -- Try API method first
                    if pTechs.GetTurnsToResearch then
                        turnsLeft = pTechs:GetTurnsToResearch(researchingTech) or 0
                    end

                    -- Fallback: calculate from progress/cost
                    if turnsLeft == 0 and sciencePerTurn > 0 then
                        local progress = 0
                        local cost = 0

                        pcall(function()
                            if pTechs.GetResearchProgress then
                                progress = pTechs:GetResearchProgress(researchingTech)
                            end
                        end)

                        -- Get cost from GameInfo
                        for techInfo in GameInfo.Technologies() do
                            if techInfo.Index == researchingTech then
                                cost = techInfo.Cost or 0
                                break
                            end
                        end

                        if cost > 0 then
                            local remaining = cost - progress
                            turnsLeft = math.ceil(remaining / sciencePerTurn)
                        end
                    end

                    currentTech = {
                        tech = techName,
                        turnsLeft = turnsLeft,
                    }
                end
            end)
        end

        -- Current civic
        local currentCivic = nil
        if pCulture and pCulture.GetProgressingCivic then
            pcall(function()
                local progressingCivic = pCulture:GetProgressingCivic()
                if progressingCivic and progressingCivic ~= -1 then
                    local civicName = ClaudeAI.GetCivicName(progressingCivic)
                    local turnsLeft = 0

                    -- Try API method first
                    if pCulture.GetTurnsToProgressCivic then
                        turnsLeft = pCulture:GetTurnsToProgressCivic(progressingCivic) or 0
                    end

                    -- Fallback: calculate from progress/cost
                    if turnsLeft == 0 and culturePerTurn > 0 then
                        local progress = 0
                        local cost = 0

                        -- Try to get progress on the CURRENT civic (not total culture)
                        pcall(function()
                            -- GetCivicProgress returns progress on specific civic
                            if pCulture.GetCivicProgress then
                                progress = pCulture:GetCivicProgress(progressingCivic) or 0
                            elseif pCulture.GetCurrentCivicProgress then
                                progress = pCulture:GetCurrentCivicProgress() or 0
                            end
                        end)

                        -- Get cost from GameInfo
                        for civicInfo in GameInfo.Civics() do
                            if civicInfo.Index == progressingCivic then
                                cost = civicInfo.Cost or 0
                                break
                            end
                        end

                        if cost > 0 and progress < cost then
                            local remaining = cost - progress
                            turnsLeft = math.ceil(remaining / culturePerTurn)
                        elseif cost > 0 then
                            turnsLeft = 1  -- Almost done
                        end
                    end

                    currentCivic = {
                        civic = civicName,
                        turnsLeft = turnsLeft,
                    }
                end
            end)
        end

        local civType = "Unknown"
        local leaderType = "Unknown"
        if PlayerConfigurations and PlayerConfigurations[playerID] then
            pcall(function()
                local config = PlayerConfigurations[playerID]
                if config.GetCivilizationTypeName then
                    civType = config:GetCivilizationTypeName() or "Unknown"
                end
                if config.GetLeaderTypeName then
                    leaderType = config:GetLeaderTypeName() or "Unknown"
                end
            end)
        end

        -- Get era and score using SafeGet helper
        local era = SafeGet(pPlayer, "GetEra") or 0
        local score = SafeGet(pPlayer, "GetScore") or 0

        result = {
            id = playerID,
            civilizationType = civType,
            leaderType = leaderType,
            gold = gold,
            goldPerTurn = goldPerTurn,
            faith = faith,
            faithPerTurn = faithPerTurn,
            sciencePerTurn = sciencePerTurn,
            culturePerTurn = culturePerTurn,
            currentTech = currentTech,
            currentCivic = currentCivic,
            era = era,
            score = score,
        }

        -- Debug logging for turns remaining
        if currentTech then
            ClaudeAI.Log("DEBUG: Tech " .. tostring(currentTech.tech) .. " turnsLeft=" .. tostring(currentTech.turnsLeft) .. " (sci/turn=" .. tostring(sciencePerTurn) .. ")")
        end
        if currentCivic then
            ClaudeAI.Log("DEBUG: Civic " .. tostring(currentCivic.civic) .. " turnsLeft=" .. tostring(currentCivic.turnsLeft) .. " (culture/turn=" .. tostring(culturePerTurn) .. ")")
        end
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error serializing player state: " .. tostring(err))
        return {id = playerID, error = "Failed to serialize"}
    end

    return result
end

-- ============================================================================
-- DIPLOMACY STATE SERIALIZATION
-- ============================================================================

function ClaudeAI.SerializeDiplomacy(playerID)
    local result = {
        metPlayers = {},
        atWarWith = {},
        hasOpenBorders = {},
        isDenounced = {},
        hasPendingDeal = false,
    }

    local success, err = pcall(function()
        local pPlayer = Players[playerID]
        if not pPlayer then return end

        local pDiplomacy = pPlayer:GetDiplomacy()
        if not pDiplomacy then return end

        -- Get our team for "has met" checks
        local myTeamID = nil
        pcall(function()
            myTeamID = pPlayer:GetTeam()
        end)

        -- Iterate through all players
        for _, pOtherPlayer in ipairs(Players) do
            local otherID = pOtherPlayer:GetID()
            if otherID ~= playerID and pOtherPlayer:IsAlive() and not pOtherPlayer:IsBarbarian() then
                local otherInfo = {
                    id = otherID,
                    civName = "Unknown",
                    leaderName = "Unknown",
                    relationship = "neutral",
                }

                -- Get civ/leader names
                pcall(function()
                    local config = PlayerConfigurations[otherID]
                    if config then
                        otherInfo.civName = config:GetCivilizationTypeName() or "Unknown"
                        otherInfo.leaderName = config:GetLeaderTypeName() or "Unknown"
                    end
                end)

                -- Check if we've met this player
                local hasMet = false
                pcall(function()
                    local otherTeamID = pOtherPlayer:GetTeam()
                    if pDiplomacy.HasMet then
                        hasMet = pDiplomacy:HasMet(otherTeamID)
                    end
                end)

                if hasMet then
                    table.insert(result.metPlayers, otherInfo)

                    -- Check war status
                    pcall(function()
                        if pDiplomacy.IsAtWarWith and pDiplomacy:IsAtWarWith(otherID) then
                            table.insert(result.atWarWith, otherID)
                            otherInfo.relationship = "war"
                        end
                    end)

                    -- Check open borders
                    pcall(function()
                        if pDiplomacy.HasOpenBordersFrom and pDiplomacy:HasOpenBordersFrom(otherID) then
                            table.insert(result.hasOpenBorders, otherID)
                        end
                    end)

                    -- Check denouncement status and track turns until casus belli
                    pcall(function()
                        if pDiplomacy.IsDenouncing and pDiplomacy:IsDenouncing(otherID) then
                            table.insert(result.isDenounced, otherID)
                            otherInfo.weDenounced = true
                            if otherInfo.relationship == "neutral" then
                                otherInfo.relationship = "hostile"
                            end

                            -- Get denounce turn to calculate turns until formal war available
                            if pDiplomacy.GetDenounceTurn then
                                local denounceTurn = pDiplomacy:GetDenounceTurn(otherID)
                                local currentTurn = Game.GetCurrentGameTurn()
                                -- Formal war requires 5 turns after denouncement
                                local turnsUntilFormalWar = math.max(0, denounceTurn + 5 - currentTurn)
                                otherInfo.turnsUntilFormalWar = turnsUntilFormalWar
                                if turnsUntilFormalWar == 0 then
                                    otherInfo.canDeclareFormally = true
                                end
                            end
                        end

                        -- Check if they denounced us
                        local pOtherDiplomacy = pOtherPlayer:GetDiplomacy()
                        if pOtherDiplomacy and pOtherDiplomacy.IsDenouncing and pOtherDiplomacy:IsDenouncing(playerID) then
                            otherInfo.theyDenouncedUs = true
                        end
                    end)

                    -- Check friendship
                    pcall(function()
                        if pDiplomacy.HasDeclaredFriendship and pDiplomacy:HasDeclaredFriendship(otherID) then
                            otherInfo.relationship = "friend"
                        end
                    end)

                    -- Check alliance
                    pcall(function()
                        if pDiplomacy.HasAlliance and pDiplomacy:HasAlliance(otherID) then
                            otherInfo.relationship = "ally"
                        end
                    end)

                    -- Check if we can declare war (not already at war, not allied)
                    pcall(function()
                        if otherInfo.relationship ~= "war" and otherInfo.relationship ~= "ally" then
                            if pDiplomacy.CanDeclareWarOn and pDiplomacy:CanDeclareWarOn(otherID) then
                                otherInfo.canDeclareWar = true
                            end
                        end
                    end)
                end
            end
        end
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error serializing diplomacy: " .. tostring(err))
    end

    return result
end

-- ============================================================================
-- AVAILABLE ACTIONS
-- ============================================================================

function ClaudeAI.GetAvailableTechs(playerID)
    local available = {}

    local success, err = pcall(function()
        local pPlayer = Players[playerID]
        if not pPlayer then return end

        local pTechs = pPlayer:GetTechs()
        if not pTechs then return end

        -- Check if methods exist
        if not pTechs.CanResearch or not pTechs.HasTech then
            ClaudeAI.Log("WARNING: Tech methods not available")
            return
        end

        for techInfo in GameInfo.Technologies() do
            -- Wrap each tech check in pcall - methods might throw "Not Implemented"
            pcall(function()
                local canResearch = pTechs:CanResearch(techInfo.Index)
                local hasTech = pTechs:HasTech(techInfo.Index)

                if canResearch and not hasTech then
                    local turns = 0
                    pcall(function()
                        if pTechs.GetTurnsToResearch then
                            turns = pTechs:GetTurnsToResearch(techInfo.Index)
                        end
                    end)
                    table.insert(available, {
                        tech = techInfo.TechnologyType,
                        turns = turns,
                    })
                end
            end)
        end
    end)

    if not success then
        ClaudeAI.Log("ERROR in GetAvailableTechs: " .. tostring(err))
    end

    return available
end

function ClaudeAI.GetAvailableCivics(playerID)
    local available = {}
    local currentCivic = nil
    local currentCivicTurns = 0

    local success, err = pcall(function()
        local pPlayer = Players[playerID]
        if not pPlayer then return end

        local pCulture = pPlayer:GetCulture()
        if not pCulture then return end

        -- HasCivic is available in gameplay context, but CanProgress is not
        -- So we manually check prerequisites using GameInfo.CivicPrereqs
        if not pCulture.HasCivic then
            ClaudeAI.Log("WARNING: HasCivic method not available")
            return
        end

        -- Get the current civic being researched
        pcall(function()
            if pCulture.GetProgressingCivic then
                local currentCivicIndex = pCulture:GetProgressingCivic()
                if currentCivicIndex and currentCivicIndex >= 0 then
                    -- Get civic name from GameInfo
                    local civicInfo = FindGameInfoByIndex(GameInfo.Civics, currentCivicIndex)
                    if civicInfo then
                        currentCivic = civicInfo.CivicType

                        -- PRIORITY 1: Try to read from UI context via ExposedMembers
                        -- UI context has access to GetCivicProgress and GetCultureYield which are UI-only
                        -- Format: "civicIndex,progress,cost,cultureYield,turnsRemaining"
                        local uiCivicProgress = ExposedMembers and ExposedMembers[EXPOSED_MEMBER_KEYS.CIVIC_PROGRESS]
                        ClaudeAI.Log("DEBUG: CIVIC_PROGRESS = " .. tostring(uiCivicProgress))
                        if uiCivicProgress and uiCivicProgress ~= "" then
                            local idx, progress, cost, cultureYield, turns = uiCivicProgress:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")
                            ClaudeAI.Log("DEBUG: Parsed idx=" .. tostring(idx) .. " currentCivicIndex=" .. tostring(currentCivicIndex))
                            if idx and tonumber(idx) == currentCivicIndex then
                                currentCivicTurns = tonumber(turns) or 0
                                ClaudeAI.Log("Civic progress from UI: " .. currentCivic ..
                                    " progress=" .. tostring(progress) .. "/" .. tostring(cost) ..
                                    " culture/turn=" .. tostring(cultureYield) .. " turns=" .. currentCivicTurns)
                            end
                        end

                        -- PRIORITY 2: Try gameplay API (may return 0 for UI-only methods)
                        if currentCivicTurns == 0 then
                            if pCulture.GetTurnsToProgressCivic then
                                local turnsResult = pCulture:GetTurnsToProgressCivic(currentCivicIndex)
                                currentCivicTurns = turnsResult or 0
                            end
                        end

                        -- PRIORITY 3: Fallback calculation using city yields
                        if currentCivicTurns == 0 then
                            local progress = 0
                            local cost = civicInfo.Cost or 0
                            local culturePerTurn = 0

                            -- Try to get progress (may be UI-only and return 0)
                            pcall(function()
                                if pCulture.GetCivicProgress then
                                    progress = pCulture:GetCivicProgress(currentCivicIndex) or 0
                                end
                            end)

                            -- Calculate culture per turn from city yields
                            pcall(function()
                                local pCities = pPlayer:GetCities()
                                if pCities and pCities.Members then
                                    for _, pCity in pCities:Members() do
                                        local cityYields = pCity:GetYields()
                                        if cityYields and cityYields.GetYield then
                                            local cityCulture = cityYields:GetYield(5) or 0  -- CULTURE = 5
                                            culturePerTurn = culturePerTurn + cityCulture
                                        end
                                    end
                                end
                            end)

                            if culturePerTurn == 0 then culturePerTurn = 1 end

                            if cost > 0 and culturePerTurn > 0 then
                                local remaining = cost - progress
                                currentCivicTurns = remaining <= 0 and 0 or math.ceil(remaining / culturePerTurn)
                                ClaudeAI.Log("Civic progress (fallback): " .. currentCivic ..
                                    " progress=" .. progress .. "/" .. cost ..
                                    " culture/turn=" .. culturePerTurn .. " turns=" .. currentCivicTurns)
                            end
                        end

                        ClaudeAI.Log("Current civic: " .. currentCivic .. " (" .. currentCivicTurns .. " turns)")
                    end
                end
            end
        end)

        -- Build a lookup of civic prerequisites
        local civicPrereqs = {}
        local prereqCount = 0
        if GameInfo.CivicPrereqs then
            for row in GameInfo.CivicPrereqs() do
                if row.Civic and row.PrereqCivic then
                    if not civicPrereqs[row.Civic] then
                        civicPrereqs[row.Civic] = {}
                    end
                    table.insert(civicPrereqs[row.Civic], row.PrereqCivic)
                    prereqCount = prereqCount + 1
                end
            end
        end
        ClaudeAI.Log("Loaded " .. prereqCount .. " civic prerequisites")

        -- Get player's current era for filtering
        local playerEraIndex = 0
        pcall(function()
            if pPlayer.GetEra then
                playerEraIndex = pPlayer:GetEra()
            elseif pPlayer.GetEras and pPlayer:GetEras().GetEra then
                playerEraIndex = pPlayer:GetEras():GetEra()
            end
        end)

        -- Build era index lookup
        local eraIndices = {}
        if GameInfo.Eras then
            for era in GameInfo.Eras() do
                eraIndices[era.EraType] = era.Index or era.ChronologyIndex or 0
            end
        end

        for civicInfo in GameInfo.Civics() do
            pcall(function()
                local civicType = civicInfo.CivicType
                local civicIndex = civicInfo.Index

                -- Check if player already has this civic
                local hasCivic = pCulture:HasCivic(civicIndex)
                if hasCivic then return end  -- Already researched

                -- Check era requirement - civic's era must be <= player's era
                local civicEra = civicInfo.EraType
                if civicEra then
                    local civicEraIndex = eraIndices[civicEra] or 0
                    if civicEraIndex > playerEraIndex then
                        return  -- Civic is from a future era
                    end
                end

                -- Check if all prerequisites are met
                local prereqs = civicPrereqs[civicType]
                local allPrereqsMet = true

                if prereqs then
                    for _, prereqCivic in ipairs(prereqs) do
                        local prereqInfo = GameInfo.Civics[prereqCivic]
                        if prereqInfo then
                            if not pCulture:HasCivic(prereqInfo.Index) then
                                allPrereqsMet = false
                                break
                            end
                        end
                    end
                end

                if allPrereqsMet then
                    local turns = 0
                    pcall(function()
                        if pCulture.GetTurnsToProgressCivic then
                            turns = pCulture:GetTurnsToProgressCivic(civicIndex)
                        end
                    end)
                    table.insert(available, {
                        civic = civicType,
                        turns = turns,
                    })
                end
            end)
        end
    end)

    if not success then
        ClaudeAI.Log("ERROR in GetAvailableCivics: " .. tostring(err))
    end

    -- Log available civics for debugging
    local civicNames = {}
    for _, c in ipairs(available) do
        table.insert(civicNames, c.civic)
    end
    ClaudeAI.Log("Available civics: " .. table.concat(civicNames, ", "))

    -- If there's a current civic in progress, add it to the result with a flag
    if currentCivic then
        -- Return current civic info along with available list
        return available, currentCivic, currentCivicTurns
    end

    return available
end

-- Get available governments for the player
function ClaudeAI.GetAvailableGovernments(playerID)
    local available = {}

    -- Skip if GameInfo.Governments doesn't exist
    if not GameInfo or not GameInfo.Governments then
        return available
    end

    local success, err = pcall(function()
        local pPlayer = Players[playerID]
        if not pPlayer then return end

        local pCulture = pPlayer:GetCulture()
        if not pCulture then return end

        -- Check if the method exists
        if not pCulture.IsGovernmentUnlocked then return end

        for govInfo in GameInfo.Governments() do
            pcall(function()
                if govInfo and govInfo.GovernmentType then
                    local govHash = govInfo.Hash
                    if not govHash and GameInfo.Types and GameInfo.Types[govInfo.GovernmentType] then
                        govHash = GameInfo.Types[govInfo.GovernmentType].Hash
                    end
                    if govHash and pCulture:IsGovernmentUnlocked(govHash) then
                        table.insert(available, {
                            government = govInfo.GovernmentType,
                            name = govInfo.Name or govInfo.GovernmentType,
                        })
                    end
                end
            end)
        end
    end)

    if not success then
        ClaudeAI.Log("ERROR in GetAvailableGovernments: " .. tostring(err))
    end

    return available
end

-- Get current government and policy info for the player
function ClaudeAI.GetGovernmentInfo(playerID)
    local info = {
        currentGovernment = nil,
        policySlots = {},
        availablePolicies = {},
    }

    -- Skip if GameInfo tables don't exist
    if not GameInfo then
        return info
    end

    local success, err = pcall(function()
        local pPlayer = Players[playerID]
        if not pPlayer then return end

        local pCulture = pPlayer:GetCulture()
        if not pCulture then return end

        -- Current government
        if pCulture.GetCurrentGovernment and GameInfo.Governments then
            pcall(function()
                local currentGovIndex = pCulture:GetCurrentGovernment()
                if currentGovIndex and currentGovIndex >= 0 then
                    for govInfo in GameInfo.Governments() do
                        if govInfo and govInfo.Index == currentGovIndex then
                            info.currentGovernment = govInfo.GovernmentType
                            break
                        end
                    end
                end
            end)
        end

        -- Policy slots and current policies
        if pCulture.GetNumPolicySlots and pCulture.GetSlotType and pCulture.GetSlotPolicy then
            pcall(function()
                local numSlots = pCulture:GetNumPolicySlots() or 0
                for slotIndex = 0, numSlots - 1 do
                    local slotType = pCulture:GetSlotType(slotIndex)
                    local slotTypeName = "SLOT_WILDCARD"  -- Default
                    if GameInfo.GovernmentSlots and GameInfo.GovernmentSlots[slotType] then
                        slotTypeName = GameInfo.GovernmentSlots[slotType].GovernmentSlotType or "SLOT_WILDCARD"
                    end

                    local currentPolicyIndex = pCulture:GetSlotPolicy(slotIndex)
                    local currentPolicyName = nil
                    if currentPolicyIndex and currentPolicyIndex >= 0 and GameInfo.Policies then
                        for policyInfo in GameInfo.Policies() do
                            if policyInfo and policyInfo.Index == currentPolicyIndex then
                                currentPolicyName = policyInfo.PolicyType
                                break
                            end
                        end
                    end

                    table.insert(info.policySlots, {
                        slotIndex = slotIndex,
                        slotType = slotTypeName,
                        currentPolicy = currentPolicyName,
                    })
                end
            end)
        end

        -- Available policies (unlocked and not obsolete)
        if GameInfo.Policies and pCulture.IsPolicyUnlocked then
            pcall(function()
                for policyInfo in GameInfo.Policies() do
                    if policyInfo and policyInfo.PolicyType then
                        local policyHash = policyInfo.Hash
                        if not policyHash and GameInfo.Types and GameInfo.Types[policyInfo.PolicyType] then
                            policyHash = GameInfo.Types[policyInfo.PolicyType].Hash
                        end
                        if policyHash then
                            local isUnlocked = pCulture:IsPolicyUnlocked(policyHash)
                            local isObsolete = pCulture.IsPolicyObsolete and pCulture:IsPolicyObsolete(policyHash)
                            if isUnlocked and not isObsolete then
                                table.insert(info.availablePolicies, {
                                    policy = policyInfo.PolicyType,
                                    slotType = policyInfo.GovernmentSlotType or "SLOT_WILDCARD",
                                })
                            end
                        end
                    end
                end
            end)
        end
    end)

    if not success then
        ClaudeAI.Log("ERROR in GetGovernmentInfo: " .. tostring(err))
    end

    return info
end

-- ============================================================================
-- MAIN GAME STATE FUNCTION
-- ============================================================================

function ClaudeAI.GetGameState(playerID)
    local pPlayer = Players[playerID]
    if not pPlayer then
        return '{"error":"Invalid player ID"}'
    end

    ClaudeAI.Log("Gathering game state for player " .. playerID)

    -- Get civics with current civic info
    local availableCivics, currentCivic, currentCivicTurns = ClaudeAI.GetAvailableCivics(playerID)

    local gameState = {
        turn = Game.GetCurrentGameTurn(),
        playerID = playerID,
        player = ClaudeAI.SerializePlayerState(playerID),
        cities = {},
        units = {},
        visibleEnemyUnits = {},
        visibleEnemyCities = {},
        availableTechs = ClaudeAI.GetAvailableTechs(playerID),
        availableCivics = availableCivics,
        -- Current civic being researched (important: don't switch away from this!)
        currentCivic = currentCivic,
        currentCivicTurns = currentCivicTurns,
        -- Government info gathered from UI context via ExposedMembers
        -- (PlayerCulture APIs only work in UI context)
        governmentInfo = ClaudeAI.GetGovernmentInfoFromUI(),
        -- Diplomacy info - met players, wars, alliances, etc.
        diplomacy = ClaudeAI.SerializeDiplomacy(playerID),
        -- Re-enabled: These only use Game.GetProperty which is safe
        strategyNotes = ClaudeAI.GetStrategyNotes(),
        tacticalNotes = ClaudeAI.GetTacticalNotes(),
    }

    -- Serialize own cities (with error handling)
    local success, err = pcall(function()
        local pCities = pPlayer:GetCities()
        if pCities and pCities.Members then
            for _, pCity in pCities:Members() do
                local cityData = ClaudeAI.SerializeCity(pCity, playerID)
                if cityData then
                    table.insert(gameState.cities, cityData)
                end
            end
        end
    end)
    if not success then
        ClaudeAI.Log("WARNING: Error serializing cities: " .. tostring(err))
    end

    -- Serialize own units (with error handling)
    success, err = pcall(function()
        local pUnits = pPlayer:GetUnits()
        if pUnits and pUnits.Members then
            for _, pUnit in pUnits:Members() do
                local unitData = ClaudeAI.SerializeUnit(pUnit)
                if unitData then
                    table.insert(gameState.units, unitData)
                end
            end
        end
    end)
    if not success then
        ClaudeAI.Log("WARNING: Error serializing units: " .. tostring(err))
    end

    -- Serialize visible enemy units and cities (with error handling)
    success, err = pcall(function()
        local pVisibility = PlayersVisibility[playerID]
        if not pVisibility then
            ClaudeAI.Log("WARNING: PlayersVisibility not available")
            return
        end

        local aliveMajors = PlayerManager.GetAliveMajors()
        if not aliveMajors then return end

        for _, otherPlayer in ipairs(aliveMajors) do
            local otherPlayerID = otherPlayer:GetID()
            if otherPlayerID ~= playerID then
                -- Enemy units
                local pUnits = otherPlayer:GetUnits()
                if pUnits and pUnits.Members then
                    for _, pUnit in pUnits:Members() do
                        local x, y = pUnit:GetX(), pUnit:GetY()
                        if pVisibility:IsVisible(x, y) then
                            local unitData = ClaudeAI.SerializeEnemyUnit(pUnit)
                            if unitData then
                                table.insert(gameState.visibleEnemyUnits, unitData)
                            end
                        end
                    end
                end

                -- Enemy cities
                local pCities = otherPlayer:GetCities()
                if pCities and pCities.Members then
                    for _, pCity in pCities:Members() do
                        local x, y = pCity:GetX(), pCity:GetY()
                        if pVisibility:IsVisible(x, y) then
                            local cityData = ClaudeAI.SerializeEnemyCity(pCity)
                            if cityData then
                                table.insert(gameState.visibleEnemyCities, cityData)
                            end
                        end
                    end
                end
            end
        end

        -- Also serialize visible BARBARIAN units (they're not in GetAliveMajors)
        local barbarianIDs = PlayerManager.GetAliveBarbarianIDs()
        if barbarianIDs then
            for _, barbPlayerID in ipairs(barbarianIDs) do
                local barbPlayer = Players[barbPlayerID]
                if barbPlayer then
                    local pUnits = barbPlayer:GetUnits()
                    if pUnits and pUnits.Members then
                        for _, pUnit in pUnits:Members() do
                            local x, y = pUnit:GetX(), pUnit:GetY()
                            if pVisibility:IsVisible(x, y) then
                                local unitData = ClaudeAI.SerializeEnemyUnit(pUnit)
                                if unitData then
                                    unitData.isBarbarian = true  -- Mark as barbarian for Claude
                                    table.insert(gameState.visibleEnemyUnits, unitData)
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    if not success then
        ClaudeAI.Log("WARNING: Error serializing enemy info: " .. tostring(err))
    end

    -- Serialize visible terrain around units/cities (with error handling)
    success, err = pcall(function()
        gameState.visibleTerrain = ClaudeAI.GetVisibleTerrain(playerID, 3)  -- 3 tile radius
    end)
    if not success then
        ClaudeAI.Log("WARNING: Error serializing terrain: " .. tostring(err))
        gameState.visibleTerrain = {}
    end

    ClaudeAI.Log("State: " .. #gameState.units .. " units, " .. #gameState.cities .. " cities, " .. #(gameState.visibleEnemyUnits or {}) .. " enemy units, " .. #(gameState.visibleTerrain or {}) .. " visible tiles")

    return ClaudeAI.TableToJSON(gameState)
end

-- ============================================================================
-- ACTION HANDLERS (dispatch table for ExecuteAction)
-- Each handler is a focused function that handles one action type
-- ============================================================================

local ActionHandlers = {}

function ActionHandlers.move_unit(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id or not action.x or not action.y then
        ClaudeAI.Log("ERROR: Move action missing unit_id, x, or y")
        return false
    end
    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found: " .. tostring(action.unit_id))
        return false
    end

    local targetX, targetY = action.x, action.y
    local startX, startY = pUnit:GetX(), pUnit:GetY()
    local maxMoves = SafeGet(pUnit, "GetMaxMoves") or 0
    local movesBefore = SafeGet(pUnit, "GetMovesRemaining") or 0

    ClaudeAI.Log("Moving unit " .. action.unit_id .. " from (" .. startX .. "," .. startY .. ") to (" .. targetX .. "," .. targetY .. ") - moves: " .. movesBefore .. "/" .. maxMoves)

    -- If already at destination, nothing to do
    if startX == targetX and startY == targetY then
        ClaudeAI.Log("Unit already at destination")
        return true
    end

    -- Helper function to check if a plot is passable for this unit
    local function IsPlotReachable(pUnit, x, y)
        -- Check if plot exists
        local pPlot = Map.GetPlot(x, y)
        if not pPlot then
            ClaudeAI.Log("Target plot (" .. x .. "," .. y .. ") does not exist")
            return false, "invalid plot"
        end

        -- Check if plot is impassable (mountains, some natural wonders)
        local isImpassable = false
        local isMountain = false
        pcall(function()
            if pPlot.IsImpassable then
                isImpassable = pPlot:IsImpassable()
            end
            if pPlot.IsMountain then
                isMountain = pPlot:IsMountain()
            end
        end)

        if isImpassable then
            -- Mountains can be passed if there's a Mountain Tunnel improvement
            if isMountain then
                local hasTunnel = false
                pcall(function()
                    local improvementType = pPlot:GetImprovementType()
                    if improvementType and improvementType >= 0 then
                        local improvementInfo = GameInfo.Improvements[improvementType]
                        if improvementInfo and improvementInfo.ImprovementType == "IMPROVEMENT_MOUNTAIN_TUNNEL" then
                            hasTunnel = true
                        end
                    end
                end)

                if hasTunnel then
                    -- Player needs Chemistry tech to use mountain tunnels
                    local hasChemistry = false
                    pcall(function()
                        local pTechs = pPlayer:GetTechs()
                        if pTechs and pTechs.HasTech then
                            local chemInfo = GameInfo.Technologies["TECH_CHEMISTRY"]
                            if chemInfo then
                                hasChemistry = pTechs:HasTech(chemInfo.Index)
                            end
                        end
                    end)

                    if hasChemistry then
                        ClaudeAI.Log("Target plot (" .. x .. "," .. y .. ") is mountain with tunnel - allowing passage")
                        -- Fall through to other checks (domain, etc.)
                    else
                        ClaudeAI.Log("Target plot (" .. x .. "," .. y .. ") has tunnel but player lacks Chemistry tech")
                        return false, "tunnel without chemistry"
                    end
                else
                    ClaudeAI.Log("Target plot (" .. x .. "," .. y .. ") is impassable mountain (no tunnel)")
                    return false, "impassable mountain"
                end
            else
                -- Non-mountain impassable (natural wonder, etc.)
                ClaudeAI.Log("Target plot (" .. x .. "," .. y .. ") is impassable (natural wonder or terrain)")
                return false, "impassable"
            end
        end

        -- Check terrain type vs unit domain
        local isWater = false
        local isOcean = false
        pcall(function()
            if pPlot.IsWater then
                isWater = pPlot:IsWater()
            end
            -- Check if it's deep ocean (not shallow/coast)
            -- IsShallowWater returns true for coast tiles, false for ocean
            if isWater and pPlot.IsShallowWater then
                local isShallow = pPlot:IsShallowWater()
                isOcean = not isShallow
            end
        end)

        local unitDomain = nil
        pcall(function()
            if pUnit.GetDomain then
                unitDomain = pUnit:GetDomain()
            end
        end)

        -- Domain constants: DOMAIN_LAND = 0, DOMAIN_SEA = 1, DOMAIN_AIR = 2
        if unitDomain == 0 and isWater then  -- Land unit trying to enter water
            -- Check if player has Sailing tech for embarkation (coast)
            local hasSailing = false
            local hasCartography = false
            pcall(function()
                local pTechs = pPlayer:GetTechs()
                if pTechs and pTechs.HasTech then
                    -- TECH_SAILING enables embarkation on coast
                    local sailingInfo = GameInfo.Technologies["TECH_SAILING"]
                    if sailingInfo then
                        hasSailing = pTechs:HasTech(sailingInfo.Index)
                    end
                    -- TECH_CARTOGRAPHY enables ocean crossing
                    local cartoInfo = GameInfo.Technologies["TECH_CARTOGRAPHY"]
                    if cartoInfo then
                        hasCartography = pTechs:HasTech(cartoInfo.Index)
                    end
                end
            end)

            if isOcean then
                -- Ocean requires both Sailing (embark) and Cartography (ocean crossing)
                if not hasSailing then
                    ClaudeAI.Log("Target plot (" .. x .. "," .. y .. ") is ocean - land unit cannot embark (no Sailing tech)")
                    return false, "ocean without embark"
                elseif not hasCartography then
                    ClaudeAI.Log("Target plot (" .. x .. "," .. y .. ") is ocean - land unit cannot cross ocean (no Cartography tech)")
                    return false, "ocean without cartography"
                end
            else
                -- Coast only requires Sailing
                if not hasSailing then
                    ClaudeAI.Log("Target plot (" .. x .. "," .. y .. ") is coast - land unit cannot embark (no Sailing tech)")
                    return false, "coast without embark"
                end
            end
        elseif unitDomain == 1 and isWater then  -- Naval unit on water
            -- Naval units also need Cartography for ocean
            if isOcean then
                local hasCartography = false
                pcall(function()
                    local pTechs = pPlayer:GetTechs()
                    if pTechs and pTechs.HasTech then
                        local cartoInfo = GameInfo.Technologies["TECH_CARTOGRAPHY"]
                        if cartoInfo then
                            hasCartography = pTechs:HasTech(cartoInfo.Index)
                        end
                    end
                end)
                if not hasCartography then
                    ClaudeAI.Log("Target plot (" .. x .. "," .. y .. ") is ocean - naval unit cannot cross ocean (no Cartography tech)")
                    return false, "ocean without cartography"
                end
            end
        elseif unitDomain == 1 and not isWater then  -- Sea unit trying to enter land
            ClaudeAI.Log("Target plot (" .. x .. "," .. y .. ") is land - naval unit cannot enter")
            return false, "land for naval"
        end

        return true, nil
    end

    -- Check if destination is reachable before attempting to move
    local canReach, reason = IsPlotReachable(pUnit, targetX, targetY)
    if not canReach then
        ClaudeAI.Log("Cannot move to (" .. targetX .. "," .. targetY .. "): " .. (reason or "unknown"))
        return false
    end

    local success, err = pcall(function()
        -- For human players, use RequestOperation which handles full pathfinding
        if isLocalPlayer and UnitManager.RequestOperation then
            local tParams = {}
            tParams[UnitOperationTypes.PARAM_X] = targetX
            tParams[UnitOperationTypes.PARAM_Y] = targetY

            -- Try MOVE_TO operation - this should handle full path
            if UnitOperationTypes.MOVE_TO then
                if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.MOVE_TO, nil, tParams) then
                    UnitManager.RequestOperation(pUnit, UnitOperationTypes.MOVE_TO, tParams)
                    ClaudeAI.Log("Moved unit using RequestOperation MOVE_TO")
                    return
                else
                    ClaudeAI.Log("CanStartOperation returned false - path may be blocked")
                end
            end

            -- Fallback: Try direct move with RequestCommand
            if UnitManager.RequestCommand and UnitCommandTypes.MOVE_TO then
                UnitManager.RequestCommand(pUnit, UnitCommandTypes.MOVE_TO, tParams)
                ClaudeAI.Log("Moved unit using RequestCommand MOVE_TO")
                return
            end
        end

        -- Fallback for AI players or if Request APIs unavailable
        -- Loop to move unit step by step until it reaches destination or runs out of moves
        if UnitManager.MoveUnit then
            local maxIterations = 10  -- Safety limit to prevent infinite loops
            local iterations = 0

            while iterations < maxIterations do
                iterations = iterations + 1
                local currentX, currentY = pUnit:GetX(), pUnit:GetY()
                local movesRemaining = SafeGet(pUnit, "GetMovesRemaining") or 0

                -- Check if we've reached the destination
                if currentX == targetX and currentY == targetY then
                    ClaudeAI.Log("Unit reached destination (" .. targetX .. "," .. targetY .. ")")
                    break
                end

                -- Check if we're out of moves
                if movesRemaining <= 0 then
                    ClaudeAI.Log("Unit out of moves at (" .. currentX .. "," .. currentY .. "), " ..
                        "target was (" .. targetX .. "," .. targetY .. ")")
                    break
                end

                -- Try to move toward the destination
                local prevX, prevY = currentX, currentY
                local prevMoves = movesRemaining
                UnitManager.MoveUnit(pUnit, targetX, targetY)

                -- Check if the unit actually moved
                local newX, newY = pUnit:GetX(), pUnit:GetY()
                local newMoves = SafeGet(pUnit, "GetMovesRemaining") or 0

                if newX == prevX and newY == prevY then
                    -- Unit didn't move - might be blocked or can't reach
                    if newMoves < prevMoves then
                        -- Moves were consumed but unit didn't move - path is blocked
                        ClaudeAI.Log("Unit path blocked at (" .. newX .. "," .. newY .. "), moves wasted, cannot reach (" .. targetX .. "," .. targetY .. ")")
                    else
                        ClaudeAI.Log("Unit stuck at (" .. newX .. "," .. newY .. "), cannot reach (" .. targetX .. "," .. targetY .. ")")
                    end
                    break
                end
            end

            local finalX, finalY = pUnit:GetX(), pUnit:GetY()
            local finalMoves = SafeGet(pUnit, "GetMovesRemaining") or 0
            ClaudeAI.Log("Move complete: unit at (" .. finalX .. "," .. finalY .. ") with " .. finalMoves .. " moves remaining")
            return
        end

        error("No movement API available")
    end)

    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to move unit: " .. tostring(err))
        return false
    end
end

function ActionHandlers.attack(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id or not action.target_x or not action.target_y then
        ClaudeAI.Log("ERROR: Attack action missing unit_id, target_x, or target_y")
        return false
    end
    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for attack: " .. tostring(action.unit_id))
        return false
    end

    local unitX, unitY = pUnit:GetX(), pUnit:GetY()
    local rangedStrength = SafeGet(pUnit, "GetRangedCombat") or 0
    local isRanged = rangedStrength > 0

    ClaudeAI.Log("Attacking with unit " .. action.unit_id .. " at (" .. action.target_x .. "," .. action.target_y .. ")" ..
        " from (" .. unitX .. "," .. unitY .. ")" .. (isRanged and " [RANGED]" or " [MELEE]"))

    local success, err = pcall(function()
        local tParams = {}
        tParams[UnitOperationTypes.PARAM_X] = action.target_x
        tParams[UnitOperationTypes.PARAM_Y] = action.target_y

        -- Try ranged attack first if unit has ranged capability
        if isRanged and isLocalPlayer and UnitManager.RequestOperation then
            if UnitOperationTypes.RANGE_ATTACK then
                if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.RANGE_ATTACK, nil, tParams) then
                    UnitManager.RequestOperation(pUnit, UnitOperationTypes.RANGE_ATTACK, tParams)
                    ClaudeAI.Log("Executed ranged attack via RequestOperation")
                    return
                end
            end
        end

        -- Try melee attack via RequestOperation for local player
        if isLocalPlayer and UnitManager.RequestOperation then
            if UnitOperationTypes.MOVE_TO then
                if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.MOVE_TO, nil, tParams) then
                    UnitManager.RequestOperation(pUnit, UnitOperationTypes.MOVE_TO, tParams)
                    ClaudeAI.Log("Executed melee attack via RequestOperation MOVE_TO")
                    return
                end
            end
        end

        -- Fallback: For melee units, move to target tile triggers combat automatically
        -- In Civ6, melee combat is initiated by moving into the enemy tile
        if UnitManager.MoveUnit then
            UnitManager.MoveUnit(pUnit, action.target_x, action.target_y)
            ClaudeAI.Log("Executed attack via MoveUnit (fallback)")
            return
        end

        error("Cannot perform attack - no attack API available")
    end)

    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to attack: " .. tostring(err))
        return false
    end
end

function ActionHandlers.found_city(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id then
        ClaudeAI.Log("ERROR: Found city action missing unit_id")
        return false
    end
    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for founding city: " .. tostring(action.unit_id))
        return false
    end
    local unitX = pUnit:GetX()
    local unitY = pUnit:GetY()
    ClaudeAI.Log("Founding city with settler " .. action.unit_id .. " at (" .. unitX .. "," .. unitY .. ")")

    local foundSuccess = false

    -- For human players, use RequestOperation (preferred)
    if isLocalPlayer and UnitManager.RequestOperation and UnitOperationTypes.FOUND_CITY then
        ClaudeAI.Log("Trying RequestOperation FOUND_CITY...")
        local success, err = pcall(function()
            if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.FOUND_CITY, nil, nil) then
                UnitManager.RequestOperation(pUnit, UnitOperationTypes.FOUND_CITY, nil)
                foundSuccess = true
                ClaudeAI.Log("RequestOperation FOUND_CITY succeeded!")
            else
                ClaudeAI.Log("CanStartOperation returned false for FOUND_CITY")
            end
        end)
        if not success then
            ClaudeAI.Log("RequestOperation FOUND_CITY failed: " .. tostring(err))
        end
    end

    -- Fallback: Try UnitManager.InitUnitOperation (gameplay context)
    if not foundSuccess and UnitManager.InitUnitOperation then
        ClaudeAI.Log("Trying UnitManager.InitUnitOperation...")
        local success, err = pcall(function()
            if UnitOperationTypes and UnitOperationTypes.FOUND_CITY then
                UnitManager.InitUnitOperation(pUnit, UnitOperationTypes.FOUND_CITY)
                foundSuccess = true
            end
        end)
        if success and foundSuccess then
            ClaudeAI.Log("InitUnitOperation succeeded!")
        else
            ClaudeAI.Log("InitUnitOperation failed: " .. tostring(err))
        end
    end

    -- Fallback: Try WorldBuilder.CityManager (if available)
    if not foundSuccess and WorldBuilder and WorldBuilder.CityManager then
        ClaudeAI.Log("Trying WorldBuilder.CityManager:Create...")
        local success, err = pcall(function()
            WorldBuilder.CityManager():Create(playerID, unitX, unitY)
            UnitManager.Kill(pUnit)
            foundSuccess = true
            ClaudeAI.Log("WorldBuilder.CityManager:Create succeeded!")
        end)
        if not success then
            ClaudeAI.Log("WorldBuilder.CityManager failed: " .. tostring(err))
        end
    end

    if foundSuccess then
        ClaudeAI.Log("City founded successfully!")
        return true
    else
        ClaudeAI.Log("ERROR: All city founding approaches failed")
        return false
    end
end

function ActionHandlers.build(playerID, action, pPlayer, isLocalPlayer)
    if not action.city_id or not action.item then
        ClaudeAI.Log("ERROR: Build action missing city_id or item")
        return false
    end
    local pCity = CityManager.GetCity(playerID, action.city_id)
    if not pCity then
        ClaudeAI.Log("ERROR: City not found: " .. tostring(action.city_id))
        return false
    end
    local itemName = action.item
    ClaudeAI.Log("BUILD REQUEST: " .. itemName .. " in city " .. action.city_id)

    -- Determine item type, hash, and prerequisites
    local itemHash = nil
    local itemType = nil
    local prereqTech = nil
    local prereqCivic = nil

    if GameInfo.Units and GameInfo.Units[itemName] then
        local info = GameInfo.Units[itemName]
        itemHash = info.Hash
        itemType = "unit"
        prereqTech = info.PrereqTech
        prereqCivic = info.PrereqCivic
        ClaudeAI.Log("BUILD DEBUG: Unit " .. itemName .. " prereqTech=" .. tostring(prereqTech) .. " prereqCivic=" .. tostring(prereqCivic))
    elseif GameInfo.Buildings and GameInfo.Buildings[itemName] then
        local info = GameInfo.Buildings[itemName]
        itemHash = info.Hash
        itemType = "building"
        prereqTech = info.PrereqTech
        prereqCivic = info.PrereqCivic
        ClaudeAI.Log("BUILD DEBUG: Building " .. itemName .. " prereqTech=" .. tostring(prereqTech) .. " prereqCivic=" .. tostring(prereqCivic))
    elseif GameInfo.Districts and GameInfo.Districts[itemName] then
        local info = GameInfo.Districts[itemName]
        itemHash = info.Hash
        itemType = "district"
        prereqTech = info.PrereqTech
        prereqCivic = info.PrereqCivic
        ClaudeAI.Log("BUILD DEBUG: District " .. itemName .. " prereqTech=" .. tostring(prereqTech) .. " prereqCivic=" .. tostring(prereqCivic))
    elseif GameInfo.Projects and GameInfo.Projects[itemName] then
        local info = GameInfo.Projects[itemName]
        itemHash = info.Hash
        itemType = "project"
        prereqTech = info.PrereqTech
        prereqCivic = info.PrereqCivic
        ClaudeAI.Log("BUILD DEBUG: Project " .. itemName .. " prereqTech=" .. tostring(prereqTech) .. " prereqCivic=" .. tostring(prereqCivic))
    else
        ClaudeAI.Log("ERROR: Could not find item in GameInfo: " .. itemName)
        return false
    end

    -- Validate prerequisites before building
    -- Check tech prerequisite
    local hasTech = ClaudeAI.HasTechPrereq(playerID, prereqTech)
    ClaudeAI.Log("BUILD DEBUG: hasTech(" .. tostring(prereqTech) .. ")=" .. tostring(hasTech))
    if not hasTech then
        ClaudeAI.Log("REJECTED build " .. itemName .. ": Missing tech prerequisite " .. tostring(prereqTech))
        return false
    end

    -- Check civic prerequisite
    local hasCivic = ClaudeAI.HasCivicPrereq(playerID, prereqCivic)
    ClaudeAI.Log("BUILD DEBUG: hasCivic(" .. tostring(prereqCivic) .. ")=" .. tostring(hasCivic))
    if not hasCivic then
        ClaudeAI.Log("REJECTED build " .. itemName .. ": Missing civic prerequisite " .. tostring(prereqCivic))
        return false
    end

    -- Check building prerequisite (e.g., Medieval Walls requires Ancient Walls)
    if itemType == "building" and GameInfo.BuildingPrereqs then
        for prereqRow in GameInfo.BuildingPrereqs() do
            if prereqRow.Building == itemName then
                local prereqBuilding = prereqRow.PrereqBuilding
                ClaudeAI.Log("BUILD DEBUG: Building " .. itemName .. " requires prereqBuilding=" .. tostring(prereqBuilding))
                if prereqBuilding then
                    local hasPrereqBuilding = ClaudeAI.CityHasBuilding(pCity, prereqBuilding)
                    ClaudeAI.Log("BUILD DEBUG: CityHasBuilding(" .. tostring(prereqBuilding) .. ")=" .. tostring(hasPrereqBuilding))
                    if not hasPrereqBuilding then
                        ClaudeAI.Log("REJECTED build " .. itemName .. ": City missing prerequisite building " .. tostring(prereqBuilding))
                        return false
                    end
                end
            end
        end
    end

    ClaudeAI.Log("BUILD DEBUG: All prerequisites passed for " .. itemName)
    ClaudeAI.Log("Queueing " .. itemType .. ": " .. itemName .. " (hash: " .. tostring(itemHash) .. ")")
    local productionSet = false

    -- For human players, use UI request to properly handle production modal
    if isLocalPlayer then
        ClaudeAI.RequestProduction(playerID, action.city_id, itemType, itemHash)
        productionSet = true  -- Assume success, UI will handle it
    end

    -- Also try gameplay API (works for AI and as backup for human)
    local pBuildQueue = SafeGet(pCity, "GetBuildQueue")

    if pBuildQueue then
        local success, err = pcall(function()
            -- Use the appropriate queue method based on item type
            if itemType == "unit" then
                local unitIndex = GameInfo.Units[itemName].Index
                pBuildQueue:CreateIncompleteBuilding(unitIndex)
                productionSet = true
            elseif itemType == "building" then
                local buildingIndex = GameInfo.Buildings[itemName].Index
                pBuildQueue:CreateIncompleteBuilding(buildingIndex)
                productionSet = true
            elseif itemType == "district" then
                local districtIndex = GameInfo.Districts[itemName].Index
                pBuildQueue:CreateIncompleteBuilding(districtIndex)
                productionSet = true
            elseif itemType == "project" then
                local projectIndex = GameInfo.Projects[itemName].Index
                pBuildQueue:CreateIncompleteBuilding(projectIndex)
                productionSet = true
            end
        end)
        if not success then
            ClaudeAI.Log("BuildQueue method failed: " .. tostring(err))
        end
    else
        ClaudeAI.Log("WARNING: Could not get build queue for city")
    end

    if productionSet then
        ClaudeAI.Log("Production set successfully")
        return true
    else
        ClaudeAI.Log("ERROR: Failed to set production")
        return false
    end
end

function ActionHandlers.research(playerID, action, pPlayer, isLocalPlayer)
    if not action.tech then
        ClaudeAI.Log("ERROR: Research action missing tech field")
        return false
    end
    ClaudeAI.Log("Researching " .. action.tech)
    local techInfo = GameInfo.Technologies[action.tech]
    if not techInfo then
        ClaudeAI.Log("ERROR: Tech not found: " .. action.tech)
        return false
    end
    local techHash = techInfo.Hash
    local techIndex = techInfo.Index

    -- For human players, use UI request to properly dismiss research modal
    if isLocalPlayer then
        ClaudeAI.RequestResearch(playerID, techHash)
    end

    -- Also set via gameplay API as backup
    local success, err = pcall(function()
        local pTechs = pPlayer:GetTechs()
        pTechs:SetResearchingTech(techIndex)
    end)
    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to set research: " .. tostring(err))
        return false
    end
end

function ActionHandlers.civic(playerID, action, pPlayer, isLocalPlayer)
    if not action.civic then
        ClaudeAI.Log("ERROR: Civic action missing civic field")
        return false
    end
    ClaudeAI.Log("Requested civic: " .. action.civic)
    local civicInfo = GameInfo.Civics[action.civic]
    if not civicInfo then
        ClaudeAI.Log("ERROR: Civic not found: " .. action.civic)
        return false
    end
    local civicHash = civicInfo.Hash
    local civicIndex = civicInfo.Index

    -- VALIDATION: Check if we should actually switch civics
    local pCulture = pPlayer:GetCulture()
    local shouldSwitch = true

    -- Check current civic in progress
    local currentCivicIndex = SafeGet(pCulture, "GetProgressingCivic") or -1

    -- If already researching this civic, just continue (no action needed)
    if currentCivicIndex == civicIndex then
        ClaudeAI.Log("Already researching " .. action.civic .. " - continuing")
        return true
    end

    -- Check if prerequisites are met for requested civic
    if GameInfo.CivicPrereqs then
        for row in GameInfo.CivicPrereqs() do
            if row.Civic == action.civic then
                local prereqInfo = GameInfo.Civics[row.PrereqCivic]
                if prereqInfo then
                    local hasPrereq = SafeCall(function() return pCulture:HasCivic(prereqInfo.Index) end, false)
                    if not hasPrereq then
                        ClaudeAI.Log("REJECTED civic change to " .. action.civic .. ": Prerequisites not met (missing " .. row.PrereqCivic .. ")")
                        return false
                    end
                end
            end
        end
    end

    ClaudeAI.Log("Progressing civic " .. action.civic)

    -- For human players, use UI request to properly dismiss civic modal
    if isLocalPlayer then
        ClaudeAI.RequestCivic(playerID, civicHash)
    end

    -- Also set via gameplay API as backup
    local success, err = pcall(function()
        pCulture:SetProgressingCivic(civicIndex)
    end)
    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to set civic: " .. tostring(err))
        return false
    end
end

function ActionHandlers.set_government(playerID, action, pPlayer, isLocalPlayer)
    if not action.government then
        ClaudeAI.Log("ERROR: set_government action missing government field")
        return false
    end
    ClaudeAI.Log("Setting government to " .. action.government)
    local governmentInfo = GameInfo.Governments[action.government]
    if not governmentInfo then
        ClaudeAI.Log("ERROR: Government not found: " .. action.government)
        return false
    end
    local governmentHash = governmentInfo.Hash

    -- For human players, use UI request
    if isLocalPlayer then
        ClaudeAI.RequestGovernment(playerID, governmentHash)
    end

    -- Also try gameplay API as backup
    local success, err = pcall(function()
        local pCulture = pPlayer:GetCulture()
        if pCulture and pCulture.RequestChangeGovernment then
            pCulture:RequestChangeGovernment(governmentHash)
        end
    end)
    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to set government: " .. tostring(err))
        return false
    end
end

function ActionHandlers.set_policies(playerID, action, pPlayer, isLocalPlayer)
    if not action.policies then
        ClaudeAI.Log("ERROR: set_policies action missing policies field")
        return false
    end
    ClaudeAI.Log("Setting policies...")

    -- Get slot types for validation (if available)
    local slotTypes = {}
    pcall(function()
        local pCulture = pPlayer:GetCulture()
        if pCulture and pCulture.GetNumPolicySlots and pCulture.GetSlotType then
            local numSlots = pCulture:GetNumPolicySlots() or 0
            for i = 0, numSlots - 1 do
                local slotTypeIndex = pCulture:GetSlotType(i)
                -- Map slot type index to name
                local slotInfo = FindGameInfoByIndex(GameInfo.GovernmentSlots, slotTypeIndex)
                if slotInfo then
                    slotTypes[i] = slotInfo.GovernmentSlotType
                end
            end
        end
    end)

    -- action.policies is a table: {[slotIndex] = "POLICY_NAME", ...}
    -- Convert to hash table with validation
    local policyAssignments = {}
    for slotIndex, policyName in pairs(action.policies) do
        local policyInfo = GameInfo.Policies[policyName]
        if policyInfo then
            local slot = tonumber(slotIndex)
            local policySlotType = policyInfo.GovernmentSlotType or "SLOT_WILDCARD"
            local targetSlotType = slotTypes[slot]

            -- Validate: policy must match slot type, or slot must be wildcard
            local isValid = true
            if targetSlotType and targetSlotType ~= "SLOT_WILDCARD" then
                if policySlotType ~= targetSlotType and policySlotType ~= "SLOT_WILDCARD" then
                    ClaudeAI.Log("WARNING: " .. policyName .. " (" .. policySlotType .. ") doesn't fit slot " .. slot .. " (" .. targetSlotType .. ")")
                    isValid = false
                end
            end

            if isValid then
                policyAssignments[slot] = policyInfo.Hash
                ClaudeAI.Log("  Slot " .. slotIndex .. ": " .. policyName .. " (" .. policySlotType .. ")")
            end
        else
            ClaudeAI.Log("WARNING: Policy not found: " .. tostring(policyName))
        end
    end

    -- For human players, use UI request
    if isLocalPlayer then
        ClaudeAI.RequestPolicy(playerID, policyAssignments)
    end

    -- Also try gameplay API as backup
    local success, err = pcall(function()
        local pCulture = pPlayer:GetCulture()
        if pCulture and pCulture.RequestPolicyChanges then
            local numSlots = pCulture:GetNumPolicySlots() or 0
            local clearList = {}
            for i = 0, numSlots - 1 do
                table.insert(clearList, i)
            end
            pCulture:RequestPolicyChanges(clearList, policyAssignments)
        end
    end)
    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to set policies: " .. tostring(err))
        return false
    end
end

function ActionHandlers.update_notes(playerID, action, pPlayer, isLocalPlayer)
    -- Update strategy notes (persistent across turns) and/or tactical notes (this turn only)
    local updated = false

    if action.strategy_notes then
        ClaudeAI.Log("Updating strategy notes...")
        ClaudeAI.SetStrategyNotes(action.strategy_notes)
        updated = true
    end

    if action.tactical_notes then
        ClaudeAI.Log("Updating tactical notes...")
        ClaudeAI.SetTacticalNotes(action.tactical_notes)
        updated = true
    end

    if updated then
        return true
    else
        ClaudeAI.Log("WARNING: update_notes action had no notes to update")
        return false
    end
end

function ActionHandlers.skip(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id then
        ClaudeAI.Log("ERROR: Skip action missing unit_id")
        return false
    end
    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for skip: " .. tostring(action.unit_id))
        return false
    end
    ClaudeAI.Log("Skipping turn for unit " .. action.unit_id)
    local success, err = pcall(function()
        if UnitManager.FinishMoves then
            UnitManager.FinishMoves(pUnit)
            ClaudeAI.Log("Unit turn skipped via FinishMoves")
        else
            error("FinishMoves not available")
        end
    end)
    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to skip unit: " .. tostring(err))
        return false
    end
end

function ActionHandlers.fortify(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id then
        ClaudeAI.Log("ERROR: Fortify action missing unit_id")
        return false
    end
    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for fortify: " .. tostring(action.unit_id))
        return false
    end
    ClaudeAI.Log("Fortifying unit " .. action.unit_id)
    local success, err = pcall(function()
        -- Try FORTIFY operation if available
        if UnitOperationTypes.FORTIFY then
            if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.FORTIFY, nil, nil) then
                UnitManager.RequestOperation(pUnit, UnitOperationTypes.FORTIFY, nil)
                ClaudeAI.Log("Unit fortified via FORTIFY operation")
                return
            end
        end
        -- Fallback: just finish moves (basic fortify behavior)
        if UnitManager.FinishMoves then
            UnitManager.FinishMoves(pUnit)
            ClaudeAI.Log("Unit fortified via FinishMoves fallback")
            return
        end
        error("No fortify method available")
    end)
    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to fortify unit: " .. tostring(err))
        return false
    end
end

function ActionHandlers.sleep(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id then
        ClaudeAI.Log("ERROR: Sleep action missing unit_id")
        return false
    end
    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for sleep: " .. tostring(action.unit_id))
        return false
    end
    ClaudeAI.Log("Putting unit " .. action.unit_id .. " to sleep")
    local success, err = pcall(function()
        if UnitOperationTypes.SLEEP then
            if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.SLEEP, nil, nil) then
                UnitManager.RequestOperation(pUnit, UnitOperationTypes.SLEEP, nil)
                ClaudeAI.Log("Unit put to sleep")
                return
            end
        end
        -- Fallback: finish moves
        if UnitManager.FinishMoves then
            UnitManager.FinishMoves(pUnit)
            ClaudeAI.Log("Unit sleeping via FinishMoves fallback")
            return
        end
        error("No sleep method available")
    end)
    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to sleep unit: " .. tostring(err))
        return false
    end
end

function ActionHandlers.delete(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id then
        ClaudeAI.Log("ERROR: Delete action missing unit_id")
        return false
    end
    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for delete: " .. tostring(action.unit_id))
        return false
    end
    ClaudeAI.Log("Deleting unit " .. action.unit_id)
    local success, err = pcall(function()
        if UnitManager.Kill then
            UnitManager.Kill(pUnit)
            ClaudeAI.Log("Unit deleted via UnitManager.Kill")
            return
        end
        error("UnitManager.Kill not available")
    end)
    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to delete unit: " .. tostring(err))
        return false
    end
end

function ActionHandlers.pillage(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id then
        ClaudeAI.Log("ERROR: Pillage action missing unit_id")
        return false
    end
    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for pillage: " .. tostring(action.unit_id))
        return false
    end
    ClaudeAI.Log("Pillaging with unit " .. action.unit_id)
    local success, err = pcall(function()
        if UnitOperationTypes.PILLAGE then
            if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.PILLAGE, nil, nil) then
                UnitManager.RequestOperation(pUnit, UnitOperationTypes.PILLAGE, nil)
                ClaudeAI.Log("Pillage operation executed")
                return
            else
                error("Cannot pillage at current location")
            end
        end
        error("PILLAGE operation not available")
    end)
    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to pillage: " .. tostring(err))
        return false
    end
end

-- ============================================================================
-- BUILDER ACTION HANDLERS
-- ============================================================================

-- Get available builder actions for a unit at its current location
function ClaudeAI.GetBuilderActions(pUnit, playerID)
    local result = {
        availableImprovements = {},
        canHarvest = false,
        harvestType = nil,
        canRemoveFeature = false,
        featureType = nil,
        canRepair = false,
    }

    if not pUnit then return result end

    local unitX, unitY = pUnit:GetX(), pUnit:GetY()
    local pPlot = Map.GetPlot(unitX, unitY)
    if not pPlot then return result end

    local pPlayer = Players[playerID]
    if not pPlayer then return result end

    local success, err = pcall(function()
        -- Get plot info
        local terrainType = pPlot:GetTerrainType()
        local featureType = pPlot:GetFeatureType()
        local resourceType = pPlot:GetResourceType()
        local improvementType = pPlot:GetImprovementType()

        -- Get terrain/feature/resource names for matching
        local terrainInfo = terrainType >= 0 and GameInfo.Terrains[terrainType] or nil
        local featureInfo = featureType >= 0 and GameInfo.Features[featureType] or nil
        local resourceInfo = resourceType >= 0 and GameInfo.Resources[resourceType] or nil

        local terrainName = terrainInfo and terrainInfo.TerrainType or nil
        local featureName = featureInfo and featureInfo.FeatureType or nil
        local resourceName = resourceInfo and resourceInfo.ResourceType or nil

        -- Check if plot is owned by the player (builders can only improve owned tiles)
        local plotOwner = pPlot:GetOwner()
        if plotOwner ~= playerID then
            ClaudeAI.Log("Builder: Plot not owned by player (owner=" .. tostring(plotOwner) .. ")")
            return
        end

        -- Check for harvestable resources (bonus resources can be harvested)
        if resourceInfo and resourceInfo.ResourceClassType == "RESOURCECLASS_BONUS" then
            result.canHarvest = true
            result.harvestType = resourceName
        end

        -- Check for removable features (woods, jungle, marsh)
        local removableFeatures = {
            ["FEATURE_FOREST"] = true,
            ["FEATURE_JUNGLE"] = true,
            ["FEATURE_MARSH"] = true,
        }
        if featureName and removableFeatures[featureName] then
            result.canRemoveFeature = true
            result.featureType = featureName
        end

        -- Check if there's a pillaged improvement that can be repaired
        if improvementType >= 0 then
            local isPillaged = false
            pcall(function()
                isPillaged = pPlot:IsImprovementPillaged()
            end)
            if isPillaged then
                result.canRepair = true
            end
        end

        -- Build list of valid improvements
        -- Check prerequisites: tech, civic, terrain, features, resources
        local pTechs = pPlayer:GetTechs()
        local pCulture = pPlayer:GetCulture()

        if GameInfo.Improvements then
            for impRow in GameInfo.Improvements() do
                local impType = impRow.ImprovementType
                local canBuild = true

                -- Skip city-specific or special improvements
                if impRow.SpecificCivRequired or impRow.TraitType then
                    canBuild = false
                end

                -- Check tech prerequisite
                if canBuild and impRow.PrereqTech then
                    local techInfo = GameInfo.Technologies[impRow.PrereqTech]
                    if techInfo then
                        local hasTech = pTechs:HasTech(techInfo.Index)
                        if not hasTech then canBuild = false end
                    end
                end

                -- Check civic prerequisite
                if canBuild and impRow.PrereqCivic then
                    local civicInfo = GameInfo.Civics[impRow.PrereqCivic]
                    if civicInfo then
                        local hasCivic = pCulture:HasCivic(civicInfo.Index)
                        if not hasCivic then canBuild = false end
                    end
                end

                -- Check valid terrains
                if canBuild and GameInfo.Improvement_ValidTerrains then
                    local hasValidTerrain = false
                    local hasTerrainReq = false
                    for row in GameInfo.Improvement_ValidTerrains() do
                        if row.ImprovementType == impType then
                            hasTerrainReq = true
                            if row.TerrainType == terrainName then
                                hasValidTerrain = true
                                break
                            end
                        end
                    end
                    if hasTerrainReq and not hasValidTerrain then canBuild = false end
                end

                -- Check valid features (some improvements require or work with features)
                if canBuild and GameInfo.Improvement_ValidFeatures then
                    local hasValidFeature = false
                    local hasFeatureReq = false
                    for row in GameInfo.Improvement_ValidFeatures() do
                        if row.ImprovementType == impType then
                            hasFeatureReq = true
                            if row.FeatureType == featureName then
                                hasValidFeature = true
                                break
                            end
                        end
                    end
                    -- If improvement requires a feature but plot doesn't have it, can't build
                    if hasFeatureReq and not hasValidFeature then canBuild = false end
                end

                -- Check valid resources (some improvements connect specific resources)
                if canBuild and GameInfo.Improvement_ValidResources then
                    local validForResource = false
                    local hasResourceReq = false
                    for row in GameInfo.Improvement_ValidResources() do
                        if row.ImprovementType == impType then
                            hasResourceReq = true
                            if row.ResourceType == resourceName then
                                validForResource = true
                                break
                            end
                        end
                    end
                    -- Resource-specific improvements (like camps, mines for resources)
                    -- should only show if resource matches
                    if hasResourceReq and not validForResource then canBuild = false end
                end

                -- Skip if there's already an improvement (unless pillaged)
                if canBuild and improvementType >= 0 then
                    local currentImpInfo = GameInfo.Improvements[improvementType]
                    if currentImpInfo then
                        local isPillaged = false
                        pcall(function() isPillaged = pPlot:IsImprovementPillaged() end)
                        if not isPillaged then
                            canBuild = false  -- Already has non-pillaged improvement
                        end
                    end
                end

                -- Check hills requirement
                if canBuild and impRow.RequiresHills and not pPlot:IsHills() then
                    canBuild = false
                end

                -- Check not on hills
                if canBuild and impRow.NoHills and pPlot:IsHills() then
                    canBuild = false
                end

                -- Skip water improvements for land units
                if canBuild and impRow.Coast and not pPlot:IsWater() then
                    canBuild = false
                end

                if canBuild then
                    table.insert(result.availableImprovements, impType)
                end
            end
        end
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error getting builder actions: " .. tostring(err))
    end

    return result
end

function ActionHandlers.build_improvement(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id or not action.improvement then
        ClaudeAI.Log("ERROR: build_improvement requires unit_id and improvement")
        return false
    end

    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for build_improvement: " .. tostring(action.unit_id))
        return false
    end

    -- Check if unit has build charges
    local charges = SafeGet(pUnit, "GetBuildCharges") or 0
    if charges <= 0 then
        ClaudeAI.Log("ERROR: Unit has no build charges remaining")
        return false
    end

    local improvementName = action.improvement
    ClaudeAI.Log("Building improvement: " .. improvementName .. " with unit " .. action.unit_id)

    -- Get improvement info
    local impInfo = GameInfo.Improvements[improvementName]
    if not impInfo then
        ClaudeAI.Log("ERROR: Improvement not found: " .. improvementName)
        return false
    end

    local success, err = pcall(function()
        if isLocalPlayer and UnitManager.RequestOperation then
            -- Use BUILD_IMPROVEMENT operation
            if UnitOperationTypes.BUILD_IMPROVEMENT then
                local tParams = {}
                tParams[UnitOperationTypes.PARAM_IMPROVEMENT_TYPE] = impInfo.Index

                if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.BUILD_IMPROVEMENT, nil, tParams) then
                    UnitManager.RequestOperation(pUnit, UnitOperationTypes.BUILD_IMPROVEMENT, tParams)
                    ClaudeAI.Log("Build improvement requested via RequestOperation")
                    return
                else
                    ClaudeAI.Log("CanStartOperation returned false for BUILD_IMPROVEMENT")
                end
            end
        end

        -- Fallback for AI or if RequestOperation not available
        if UnitManager.PlaceBuilding then
            UnitManager.PlaceBuilding(pUnit, impInfo.Index)
            ClaudeAI.Log("Build improvement via PlaceBuilding")
            return
        end

        error("No build improvement API available")
    end)

    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to build improvement: " .. tostring(err))
        return false
    end
end

function ActionHandlers.harvest(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id then
        ClaudeAI.Log("ERROR: harvest requires unit_id")
        return false
    end

    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for harvest: " .. tostring(action.unit_id))
        return false
    end

    ClaudeAI.Log("Harvesting resource with unit " .. action.unit_id)

    local success, err = pcall(function()
        if isLocalPlayer and UnitManager.RequestOperation then
            if UnitOperationTypes.HARVEST_RESOURCE then
                if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.HARVEST_RESOURCE, nil, nil) then
                    UnitManager.RequestOperation(pUnit, UnitOperationTypes.HARVEST_RESOURCE, nil)
                    ClaudeAI.Log("Harvest requested via RequestOperation")
                    return
                else
                    ClaudeAI.Log("CanStartOperation returned false for HARVEST_RESOURCE")
                end
            end
        end
        error("No harvest API available")
    end)

    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to harvest: " .. tostring(err))
        return false
    end
end

function ActionHandlers.remove_feature(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id then
        ClaudeAI.Log("ERROR: remove_feature requires unit_id")
        return false
    end

    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for remove_feature: " .. tostring(action.unit_id))
        return false
    end

    ClaudeAI.Log("Removing feature with unit " .. action.unit_id)

    local success, err = pcall(function()
        if isLocalPlayer and UnitManager.RequestOperation then
            if UnitOperationTypes.REMOVE_FEATURE then
                if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.REMOVE_FEATURE, nil, nil) then
                    UnitManager.RequestOperation(pUnit, UnitOperationTypes.REMOVE_FEATURE, nil)
                    ClaudeAI.Log("Remove feature requested via RequestOperation")
                    return
                else
                    ClaudeAI.Log("CanStartOperation returned false for REMOVE_FEATURE")
                end
            end
        end
        error("No remove feature API available")
    end)

    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to remove feature: " .. tostring(err))
        return false
    end
end

-- Get available trade route destinations for a trader unit
function ClaudeAI.GetTradeRouteDestinations(pUnit, playerID)
    local destinations = {}

    if not pUnit then return destinations end

    local pPlayer = Players[playerID]
    if not pPlayer then return destinations end

    local success, err = pcall(function()
        local pTrade = pPlayer:GetTrade()
        if not pTrade then
            ClaudeAI.Log("Trade: Player trade object not available")
            return
        end

        -- Get the unit's origin city
        local unitX, unitY = pUnit:GetX(), pUnit:GetY()
        local originCity = nil

        -- Find the city the trader is in (or nearest)
        local pCities = pPlayer:GetCities()
        if pCities and pCities.Members then
            for _, pCity in pCities:Members() do
                if pCity:GetX() == unitX and pCity:GetY() == unitY then
                    originCity = pCity
                    break
                end
            end
            -- If not in a city, use capital
            if not originCity then
                originCity = pCities:GetCapitalCity()
            end
        end

        if not originCity then
            ClaudeAI.Log("Trade: No origin city found for trader")
            return
        end

        local originCityID = originCity:GetID()

        -- Get domestic destinations (own cities)
        for _, pCity in pCities:Members() do
            if pCity:GetID() ~= originCityID then
                local cityInfo = {
                    cityID = pCity:GetID(),
                    cityName = SafeGet(pCity, "GetName") or "Unknown",
                    ownerID = playerID,
                    isDomestic = true,
                    x = pCity:GetX(),
                    y = pCity:GetY(),
                }

                -- Try to get yields (may not be available in gameplay context)
                pcall(function()
                    if pTrade.CanHaveTradeRouteFrom then
                        local canTrade = pTrade:CanHaveTradeRouteFrom(originCity, pCity)
                        if canTrade then
                            table.insert(destinations, cityInfo)
                        end
                    else
                        -- Fallback: assume all own cities are valid
                        table.insert(destinations, cityInfo)
                    end
                end)
            end
        end

        -- Get international destinations (other civs' cities we have visibility to)
        local aliveMajors = PlayerManager.GetAliveMajors()
        if aliveMajors then
            local pVisibility = PlayersVisibility[playerID]

            for _, pOtherPlayer in ipairs(aliveMajors) do
                local otherPlayerID = pOtherPlayer:GetID()
                if otherPlayerID ~= playerID then
                    -- Check if we have met this player
                    local hasMet = false
                    pcall(function()
                        local pDiplomacy = pPlayer:GetDiplomacy()
                        local otherTeam = pOtherPlayer:GetTeam()
                        hasMet = pDiplomacy and pDiplomacy:HasMet(otherTeam)
                    end)

                    if hasMet then
                        local pOtherCities = pOtherPlayer:GetCities()
                        if pOtherCities and pOtherCities.Members then
                            for _, pOtherCity in pOtherCities:Members() do
                                local cityX, cityY = pOtherCity:GetX(), pOtherCity:GetY()

                                -- Check visibility
                                local isVisible = true
                                if pVisibility then
                                    pcall(function()
                                        isVisible = pVisibility:IsRevealed(cityX, cityY)
                                    end)
                                end

                                if isVisible then
                                    local cityInfo = {
                                        cityID = pOtherCity:GetID(),
                                        cityName = SafeGet(pOtherCity, "GetName") or "Unknown",
                                        ownerID = otherPlayerID,
                                        isDomestic = false,
                                        x = cityX,
                                        y = cityY,
                                    }
                                    table.insert(destinations, cityInfo)
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error getting trade destinations: " .. tostring(err))
    end

    return destinations
end

-- Get upgrade info for a unit
function ClaudeAI.GetUnitUpgradeInfo(pUnit, playerID)
    local result = {
        canUpgrade = false,
        upgradeType = nil,
        cost = 0,
    }

    if not pUnit then return result end

    local pPlayer = Players[playerID]
    if not pPlayer then return result end

    local success, err = pcall(function()
        local unitType = pUnit:GetType()
        local unitInfo = GameInfo.Units[unitType]
        if not unitInfo then return end

        local unitTypeName = unitInfo.UnitType

        -- Find upgrade path in GameInfo.UnitUpgrades
        local upgradeTarget = nil
        if GameInfo.UnitUpgrades then
            for row in GameInfo.UnitUpgrades() do
                if row.Unit == unitTypeName then
                    upgradeTarget = row.UpgradeUnit
                    break
                end
            end
        end

        if not upgradeTarget then return end  -- No upgrade available

        -- Get target unit info
        local targetInfo = GameInfo.Units[upgradeTarget]
        if not targetInfo then return end

        -- Check tech prerequisite for target unit
        if targetInfo.PrereqTech then
            local hasTech = ClaudeAI.HasTechPrereq(playerID, targetInfo.PrereqTech)
            if not hasTech then return end  -- Don't have tech yet
        end

        -- Check civic prerequisite
        if targetInfo.PrereqCivic then
            local hasCivic = ClaudeAI.HasCivicPrereq(playerID, targetInfo.PrereqCivic)
            if not hasCivic then return end
        end

        -- Calculate upgrade cost (base cost difference * modifier)
        -- Civ6 formula: (TargetCost - CurrentCost) * UpgradeCostModifier
        local baseCost = targetInfo.Cost - unitInfo.Cost
        if baseCost < 0 then baseCost = 0 end

        -- Apply discount from policies/abilities (simplified - assume base multiplier)
        local cost = math.ceil(baseCost * 0.5)  -- 50% of production difference
        if cost < 10 then cost = 10 end  -- Minimum cost

        -- Check if player has enough gold
        local pTreasury = pPlayer:GetTreasury()
        local gold = pTreasury and pTreasury:GetGoldBalance() or 0

        if gold >= cost then
            result.canUpgrade = true
            result.upgradeType = upgradeTarget
            result.cost = cost
        end
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error getting unit upgrade info: " .. tostring(err))
    end

    return result
end

-- Get purchasable items for a city (gold and faith)
function ClaudeAI.GetPurchasableItems(pCity, playerID)
    local result = {
        goldUnits = {},
        goldBuildings = {},
        faithUnits = {},
        faithBuildings = {},
    }

    if not pCity then return result end

    local pPlayer = Players[playerID]
    if not pPlayer then return result end

    local success, err = pcall(function()
        local pTreasury = pPlayer:GetTreasury()
        local pReligion = pPlayer:GetReligion()
        local gold = pTreasury and pTreasury:GetGoldBalance() or 0
        local faith = pReligion and pReligion:GetFaithBalance() or 0

        local pBuildQueue = pCity:GetBuildQueue()
        if not pBuildQueue then return end

        -- Check purchasable units with gold
        if GameInfo.Units then
            for unitInfo in GameInfo.Units() do
                local canPurchase = false
                local purchaseCost = 0

                pcall(function()
                    if pBuildQueue.GetUnitPurchaseCost then
                        purchaseCost = pBuildQueue:GetUnitPurchaseCost(unitInfo.Index)
                        if purchaseCost and purchaseCost > 0 and purchaseCost <= gold then
                            -- Check if actually purchasable (has prereqs, etc.)
                            if pBuildQueue.CanPurchase then
                                canPurchase = pBuildQueue:CanPurchase(unitInfo.Index, true)  -- true = check gold
                            else
                                canPurchase = true  -- Assume can purchase if cost is known
                            end
                        end
                    end
                end)

                if canPurchase and purchaseCost > 0 then
                    table.insert(result.goldUnits, {
                        type = unitInfo.UnitType,
                        cost = purchaseCost,
                    })
                end

                -- Check faith purchase
                local faithCost = 0
                local canFaithPurchase = false
                pcall(function()
                    if pBuildQueue.GetUnitFaithPurchaseCost then
                        faithCost = pBuildQueue:GetUnitFaithPurchaseCost(unitInfo.Index)
                        if faithCost and faithCost > 0 and faithCost <= faith then
                            canFaithPurchase = true
                        end
                    end
                end)

                if canFaithPurchase and faithCost > 0 then
                    table.insert(result.faithUnits, {
                        type = unitInfo.UnitType,
                        cost = faithCost,
                    })
                end
            end
        end

        -- Check purchasable buildings with gold
        if GameInfo.Buildings then
            for buildingInfo in GameInfo.Buildings() do
                -- Skip wonders - can't purchase those
                if not buildingInfo.IsWonder then
                    local canPurchase = false
                    local purchaseCost = 0

                    pcall(function()
                        if pBuildQueue.GetBuildingPurchaseCost then
                            purchaseCost = pBuildQueue:GetBuildingPurchaseCost(buildingInfo.Index)
                            if purchaseCost and purchaseCost > 0 and purchaseCost <= gold then
                                -- Check if city already has this building
                                local pBuildings = pCity:GetBuildings()
                                local hasBuilding = pBuildings and pBuildings:HasBuilding(buildingInfo.Index)
                                if not hasBuilding then
                                    canPurchase = true
                                end
                            end
                        end
                    end)

                    if canPurchase and purchaseCost > 0 then
                        table.insert(result.goldBuildings, {
                            type = buildingInfo.BuildingType,
                            cost = purchaseCost,
                        })
                    end

                    -- Faith purchase for buildings
                    local faithCost = 0
                    local canFaithPurchase = false
                    pcall(function()
                        if pBuildQueue.GetBuildingFaithPurchaseCost then
                            faithCost = pBuildQueue:GetBuildingFaithPurchaseCost(buildingInfo.Index)
                            if faithCost and faithCost > 0 and faithCost <= faith then
                                local pBuildings = pCity:GetBuildings()
                                local hasBuilding = pBuildings and pBuildings:HasBuilding(buildingInfo.Index)
                                if not hasBuilding then
                                    canFaithPurchase = true
                                end
                            end
                        end
                    end)

                    if canFaithPurchase and faithCost > 0 then
                        table.insert(result.faithBuildings, {
                            type = buildingInfo.BuildingType,
                            cost = faithCost,
                        })
                    end
                end
            end
        end
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error getting purchasable items: " .. tostring(err))
    end

    return result
end

-- Get city combat info (can attack, targets in range)
function ClaudeAI.GetCityCombatInfo(pCity, playerID)
    local result = {
        canAttack = false,
        rangedStrength = 0,
        range = 2,  -- Default city range
        targets = {},
    }

    if not pCity then return result end

    local success, err = pcall(function()
        local cityX, cityY = pCity:GetX(), pCity:GetY()

        -- Get city combat strength
        local pCityDistrict = pCity:GetDistricts():GetDistrict(GameInfo.Districts["DISTRICT_CITY_CENTER"].Index)
        if pCityDistrict then
            -- Check if city can attack (has walls, hasn't attacked this turn)
            local canAttack = false
            pcall(function()
                if pCityDistrict.CanAttack then
                    canAttack = pCityDistrict:CanAttack()
                end
            end)

            -- Get ranged strength
            local strength = 0
            pcall(function()
                if pCityDistrict.GetCombatStrength then
                    strength = pCityDistrict:GetCombatStrength()
                elseif pCityDistrict.GetDefenseStrength then
                    strength = pCityDistrict:GetDefenseStrength()
                end
            end)

            result.canAttack = canAttack
            result.rangedStrength = strength
        end

        -- If city can attack, find valid targets in range
        if result.canAttack and result.rangedStrength > 0 then
            local pPlayer = Players[playerID]
            local pDiplomacy = pPlayer:GetDiplomacy()

            -- Scan tiles in range for enemy units
            local range = result.range
            for dx = -range, range do
                for dy = -range, range do
                    local distance = math.abs(dx) + math.abs(dy)
                    if distance > 0 and distance <= range then
                        local checkX = cityX + dx
                        local checkY = cityY + dy
                        local pPlot = Map.GetPlot(checkX, checkY)

                        if pPlot then
                            -- Check for enemy units on this plot
                            local unitCount = pPlot:GetUnitCount()
                            for i = 0, unitCount - 1 do
                                local pUnit = pPlot:GetUnit(i)
                                if pUnit then
                                    local ownerID = pUnit:GetOwner()
                                    if ownerID ~= playerID then
                                        -- Check if at war
                                        local isEnemy = false
                                        pcall(function()
                                            if ownerID == 63 then  -- Barbarians
                                                isEnemy = true
                                            elseif pDiplomacy and pDiplomacy.IsAtWarWith then
                                                isEnemy = pDiplomacy:IsAtWarWith(ownerID)
                                            end
                                        end)

                                        if isEnemy then
                                            local unitTypeName = ClaudeAI.GetUnitName(pUnit:GetType())
                                            local damage = SafeGet(pUnit, "GetDamage") or 0
                                            local maxDamage = SafeGet(pUnit, "GetMaxDamage") or 100

                                            table.insert(result.targets, {
                                                x = checkX,
                                                y = checkY,
                                                unitType = unitTypeName,
                                                health = maxDamage - damage,
                                            })
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error getting city combat info: " .. tostring(err))
    end

    return result
end

-- Get unit promotion info
function ClaudeAI.GetUnitPromotionInfo(pUnit)
    local result = {
        canPromote = false,
        availablePromotions = {},
        currentPromotions = {},
        experience = 0,
        level = 0,
    }

    if not pUnit then return result end

    local success, err = pcall(function()
        local pUnitExperience = pUnit:GetExperience()
        if not pUnitExperience then return end

        -- Get current experience and level
        pcall(function()
            if pUnitExperience.GetExperiencePoints then
                result.experience = pUnitExperience:GetExperiencePoints() or 0
            end
            if pUnitExperience.GetLevel then
                result.level = pUnitExperience:GetLevel() or 1
            end
        end)

        -- Check if unit can be promoted
        pcall(function()
            if pUnitExperience.CanPromote then
                result.canPromote = pUnitExperience:CanPromote()
            end
        end)

        -- Get available promotions if can promote
        if result.canPromote then
            pcall(function()
                -- Get unit's promotion class
                local unitType = pUnit:GetType()
                local unitInfo = GameInfo.Units[unitType]
                if unitInfo and unitInfo.PromotionClass then
                    local promotionClass = unitInfo.PromotionClass

                    -- Find promotions for this class
                    if GameInfo.UnitPromotions then
                        for promoRow in GameInfo.UnitPromotions() do
                            if promoRow.PromotionClass == promotionClass then
                                -- Check if unit already has this promotion
                                local hasPromo = false
                                pcall(function()
                                    if pUnitExperience.HasPromotion then
                                        hasPromo = pUnitExperience:HasPromotion(promoRow.Index)
                                    end
                                end)

                                if not hasPromo then
                                    -- Check prerequisites
                                    local meetsPrereqs = true

                                    -- Check if prerequisites are met
                                    if GameInfo.UnitPromotionPrereqs then
                                        for prereqRow in GameInfo.UnitPromotionPrereqs() do
                                            if prereqRow.UnitPromotion == promoRow.PromotionType then
                                                local prereqPromo = GameInfo.UnitPromotions[prereqRow.PrereqUnitPromotion]
                                                if prereqPromo then
                                                    local hasPrereq = false
                                                    pcall(function()
                                                        hasPrereq = pUnitExperience:HasPromotion(prereqPromo.Index)
                                                    end)
                                                    if not hasPrereq then
                                                        meetsPrereqs = false
                                                        break
                                                    end
                                                end
                                            end
                                        end
                                    end

                                    if meetsPrereqs then
                                        table.insert(result.availablePromotions, {
                                            type = promoRow.PromotionType,
                                            name = promoRow.Name or promoRow.PromotionType,
                                        })
                                    end
                                end
                            end
                        end
                    end
                end
            end)
        end

        -- Get current promotions
        pcall(function()
            if GameInfo.UnitPromotions then
                for promoRow in GameInfo.UnitPromotions() do
                    local hasPromo = false
                    pcall(function()
                        if pUnitExperience.HasPromotion then
                            hasPromo = pUnitExperience:HasPromotion(promoRow.Index)
                        end
                    end)
                    if hasPromo then
                        table.insert(result.currentPromotions, promoRow.PromotionType)
                    end
                end
            end
        end)
    end)

    if not success then
        ClaudeAI.Log("WARNING: Error getting promotion info: " .. tostring(err))
    end

    return result
end

function ActionHandlers.place_district(playerID, action, pPlayer, isLocalPlayer)
    if not action.city_id or not action.district or not action.x or not action.y then
        ClaudeAI.Log("ERROR: place_district requires city_id, district, x, and y")
        return false
    end

    local pCity = CityManager.GetCity(playerID, action.city_id)
    if not pCity then
        ClaudeAI.Log("ERROR: City not found for place_district: " .. tostring(action.city_id))
        return false
    end

    local districtName = action.district
    local plotX = action.x
    local plotY = action.y

    ClaudeAI.Log("Placing " .. districtName .. " at (" .. plotX .. "," .. plotY .. ") for city " .. action.city_id)

    -- Get district info
    local districtInfo = GameInfo.Districts[districtName]
    if not districtInfo then
        ClaudeAI.Log("ERROR: District not found: " .. districtName)
        return false
    end

    -- Validate the plot
    local pPlot = Map.GetPlot(plotX, plotY)
    if not pPlot then
        ClaudeAI.Log("ERROR: Invalid plot coordinates")
        return false
    end

    local success, err = pcall(function()
        if isLocalPlayer then
            -- Use UI request for district placement
            -- Format: playerID,cityID,districtHash,plotX,plotY
            local requestStr = playerID .. "," .. action.city_id .. "," .. districtInfo.Hash .. "," .. plotX .. "," .. plotY
            Game.SetProperty(PROPERTY_KEYS.REQUEST_PLACE_DISTRICT, requestStr)
            ClaudeAI.Log("District placement request sent via Game property")
            return
        end

        -- Direct API for AI players (may require different approach)
        local pBuildQueue = pCity:GetBuildQueue()
        if pBuildQueue then
            -- Try to place district at specific location
            if pBuildQueue.CreateIncompleteDistrict then
                pBuildQueue:CreateIncompleteDistrict(districtInfo.Index, plotX, plotY, 100)  -- 100% completion target
                ClaudeAI.Log("District placed via CreateIncompleteDistrict")
                return
            end
        end

        error("No district placement API available")
    end)

    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to place district: " .. tostring(err))
        return false
    end
end

function ActionHandlers.promote(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id or not action.promotion then
        ClaudeAI.Log("ERROR: promote requires unit_id and promotion")
        return false
    end

    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for promote: " .. tostring(action.unit_id))
        return false
    end

    local promotionName = action.promotion
    ClaudeAI.Log("Promoting unit " .. action.unit_id .. " with " .. promotionName)

    -- Get promotion info
    local promoInfo = GameInfo.UnitPromotions[promotionName]
    if not promoInfo then
        ClaudeAI.Log("ERROR: Promotion not found: " .. promotionName)
        return false
    end

    local success, err = pcall(function()
        if isLocalPlayer and UnitManager.RequestCommand then
            if UnitCommandTypes.PROMOTE then
                local tParams = {}
                tParams[UnitCommandTypes.PARAM_PROMOTION_TYPE] = promoInfo.Index

                if UnitManager.CanStartCommand(pUnit, UnitCommandTypes.PROMOTE, tParams) then
                    UnitManager.RequestCommand(pUnit, UnitCommandTypes.PROMOTE, tParams)
                    ClaudeAI.Log("Promotion requested via RequestCommand")
                    return
                else
                    ClaudeAI.Log("CanStartCommand returned false for PROMOTE")
                end
            end
        end

        -- Fallback: try direct API
        local pUnitExperience = pUnit:GetExperience()
        if pUnitExperience and pUnitExperience.SetPromotion then
            pUnitExperience:SetPromotion(promoInfo.Index)
            ClaudeAI.Log("Promotion set via direct API")
            return
        end

        error("No promotion API available")
    end)

    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to promote: " .. tostring(err))
        return false
    end
end

function ActionHandlers.city_ranged_attack(playerID, action, pPlayer, isLocalPlayer)
    if not action.city_id or not action.target_x or not action.target_y then
        ClaudeAI.Log("ERROR: city_ranged_attack requires city_id, target_x, target_y")
        return false
    end

    local pCity = CityManager.GetCity(playerID, action.city_id)
    if not pCity then
        ClaudeAI.Log("ERROR: City not found for attack: " .. tostring(action.city_id))
        return false
    end

    ClaudeAI.Log("City " .. action.city_id .. " attacking target at " .. action.target_x .. "," .. action.target_y)

    local success, err = pcall(function()
        -- Get the city center district
        local pCityDistrict = pCity:GetDistricts():GetDistrict(GameInfo.Districts["DISTRICT_CITY_CENTER"].Index)
        if not pCityDistrict then
            error("City center district not found")
        end

        if isLocalPlayer then
            -- Use UI context for city attack
            if CityManager.RequestCommand then
                local tParams = {}
                tParams.X = action.target_x
                tParams.Y = action.target_y

                if CityManager.CanStartCommand and CityManager.CanStartCommand(pCity, CityCommandTypes.RANGE_ATTACK, tParams) then
                    CityManager.RequestCommand(pCity, CityCommandTypes.RANGE_ATTACK, tParams)
                    ClaudeAI.Log("City attack requested via CityManager.RequestCommand")
                    return
                end
            end

            -- Fallback: try direct district operation
            if DistrictManager and DistrictManager.RequestOperation then
                local tParams = {}
                tParams[UnitOperationTypes.PARAM_X] = action.target_x
                tParams[UnitOperationTypes.PARAM_Y] = action.target_y

                DistrictManager.RequestOperation(pCityDistrict, "DISTRICT_RANGE_ATTACK", tParams)
                ClaudeAI.Log("City attack requested via DistrictManager")
                return
            end
        end

        error("No city attack API available")
    end)

    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed city ranged attack: " .. tostring(err))
        return false
    end
end

function ActionHandlers.purchase(playerID, action, pPlayer, isLocalPlayer)
    if not action.city_id or not action.item then
        ClaudeAI.Log("ERROR: purchase requires city_id and item")
        return false
    end

    local currency = action.currency or "gold"  -- Default to gold
    local pCity = CityManager.GetCity(playerID, action.city_id)
    if not pCity then
        ClaudeAI.Log("ERROR: City not found for purchase: " .. tostring(action.city_id))
        return false
    end

    ClaudeAI.Log("Purchasing " .. action.item .. " with " .. currency .. " in city " .. action.city_id)

    local success, err = pcall(function()
        local pBuildQueue = pCity:GetBuildQueue()
        if not pBuildQueue then
            error("No build queue for city")
        end

        -- Determine item type (unit or building)
        local itemIndex = nil
        local isUnit = false

        if GameInfo.Units and GameInfo.Units[action.item] then
            itemIndex = GameInfo.Units[action.item].Index
            isUnit = true
        elseif GameInfo.Buildings and GameInfo.Buildings[action.item] then
            itemIndex = GameInfo.Buildings[action.item].Index
            isUnit = false
        else
            error("Item not found: " .. action.item)
        end

        if isLocalPlayer then
            -- Use UI request for purchases
            local requestStr = playerID .. "," .. action.city_id .. "," .. currency .. "," .. action.item
            Game.SetProperty(PROPERTY_KEYS.REQUEST_PURCHASE, requestStr)
            ClaudeAI.Log("Purchase request sent via Game property")
            return
        end

        -- Direct API for AI players (may not work)
        if isUnit then
            if currency == "gold" then
                pBuildQueue:PurchaseUnit(itemIndex)
            else
                pBuildQueue:PurchaseUnitWithFaith(itemIndex)
            end
        else
            if currency == "gold" then
                pBuildQueue:PurchaseBuilding(itemIndex)
            else
                pBuildQueue:PurchaseBuildingWithFaith(itemIndex)
            end
        end
        ClaudeAI.Log("Purchase executed via direct API")
    end)

    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to purchase: " .. tostring(err))
        return false
    end
end

function ActionHandlers.upgrade_unit(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id then
        ClaudeAI.Log("ERROR: upgrade_unit requires unit_id")
        return false
    end

    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for upgrade: " .. tostring(action.unit_id))
        return false
    end

    ClaudeAI.Log("Upgrading unit " .. action.unit_id)

    local success, err = pcall(function()
        if isLocalPlayer and UnitManager.RequestOperation then
            if UnitOperationTypes.UPGRADE then
                if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.UPGRADE, nil, nil) then
                    UnitManager.RequestOperation(pUnit, UnitOperationTypes.UPGRADE, nil)
                    ClaudeAI.Log("Upgrade requested via RequestOperation")
                    return
                else
                    ClaudeAI.Log("CanStartOperation returned false for UPGRADE")
                end
            end

            -- Try command version
            if UnitCommandTypes and UnitCommandTypes.UPGRADE then
                if UnitManager.CanStartCommand(pUnit, UnitCommandTypes.UPGRADE, nil) then
                    UnitManager.RequestCommand(pUnit, UnitCommandTypes.UPGRADE, nil)
                    ClaudeAI.Log("Upgrade requested via RequestCommand")
                    return
                end
            end
        end

        error("No upgrade API available")
    end)

    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to upgrade unit: " .. tostring(err))
        return false
    end
end

function ActionHandlers.send_trade_route(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id or not action.destination_city_id then
        ClaudeAI.Log("ERROR: send_trade_route requires unit_id and destination_city_id")
        return false
    end

    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for send_trade_route: " .. tostring(action.unit_id))
        return false
    end

    -- Verify it's a trader
    local unitType = pUnit:GetType()
    local unitInfo = GameInfo.Units[unitType]
    local unitTypeName = unitInfo and unitInfo.UnitType or "Unknown"
    if unitTypeName ~= "UNIT_TRADER" then
        ClaudeAI.Log("ERROR: Unit is not a trader: " .. unitTypeName)
        return false
    end

    local destCityID = action.destination_city_id
    local destOwnerID = action.destination_owner_id or playerID  -- Default to own city

    ClaudeAI.Log("Sending trade route to city " .. destCityID .. " (owner: " .. destOwnerID .. ")")

    local success, err = pcall(function()
        if isLocalPlayer and UnitManager.RequestOperation then
            if UnitOperationTypes.MAKE_TRADE_ROUTE then
                local tParams = {}
                -- Set destination city parameters
                tParams[UnitOperationTypes.PARAM_X] = action.destination_x
                tParams[UnitOperationTypes.PARAM_Y] = action.destination_y

                if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.MAKE_TRADE_ROUTE, nil, tParams) then
                    UnitManager.RequestOperation(pUnit, UnitOperationTypes.MAKE_TRADE_ROUTE, tParams)
                    ClaudeAI.Log("Trade route requested via RequestOperation")
                    return
                else
                    ClaudeAI.Log("CanStartOperation returned false for MAKE_TRADE_ROUTE")
                end
            end
        end

        error("No trade route API available")
    end)

    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to send trade route: " .. tostring(err))
        return false
    end
end

function ActionHandlers.repair(playerID, action, pPlayer, isLocalPlayer)
    if not action.unit_id then
        ClaudeAI.Log("ERROR: repair requires unit_id")
        return false
    end

    local pUnit = UnitManager.GetUnit(playerID, action.unit_id)
    if not pUnit then
        ClaudeAI.Log("ERROR: Unit not found for repair: " .. tostring(action.unit_id))
        return false
    end

    ClaudeAI.Log("Repairing improvement with unit " .. action.unit_id)

    local success, err = pcall(function()
        if isLocalPlayer and UnitManager.RequestOperation then
            if UnitOperationTypes.REPAIR then
                if UnitManager.CanStartOperation(pUnit, UnitOperationTypes.REPAIR, nil, nil) then
                    UnitManager.RequestOperation(pUnit, UnitOperationTypes.REPAIR, nil)
                    ClaudeAI.Log("Repair requested via RequestOperation")
                    return
                else
                    ClaudeAI.Log("CanStartOperation returned false for REPAIR")
                end
            end
        end
        error("No repair API available")
    end)

    if success then
        return true
    else
        ClaudeAI.Log("ERROR: Failed to repair: " .. tostring(err))
        return false
    end
end

-- ============================================================================
-- DIPLOMACY ACTION HANDLERS
-- ============================================================================

function ActionHandlers.dismiss_diplomacy(playerID, action, pPlayer, isLocalPlayer)
    ClaudeAI.Log("Dismissing diplomacy popups")
    if isLocalPlayer then
        ClaudeAI.RequestDiplomacyAction("dismiss")
    end
    return true
end

function ActionHandlers.declare_war(playerID, action, pPlayer, isLocalPlayer)
    if not action.target_player then
        ClaudeAI.Log("ERROR: declare_war requires target_player")
        return false
    end

    local targetPlayerID = action.target_player
    -- War types: SURPRISE, FORMAL, HOLY, LIBERATION, RECONQUEST, PROTECTORATE, COLONIAL, TERRITORIAL
    local warType = action.war_type or "SURPRISE"
    ClaudeAI.Log("Declaring " .. warType .. " war on player " .. targetPlayerID)

    if isLocalPlayer then
        -- Use UI context for war declaration with proper casus belli
        ClaudeAI.RequestDiplomacyAction("declare_war," .. targetPlayerID .. "," .. warType)
    else
        -- For AI players, use gameplay API directly
        local success, err = pcall(function()
            local pDiplomacy = pPlayer:GetDiplomacy()
            if pDiplomacy and pDiplomacy.DeclareWarOn then
                pDiplomacy:DeclareWarOn(targetPlayerID)
            end
        end)
        if not success then
            ClaudeAI.Log("ERROR: Failed to declare war: " .. tostring(err))
            return false
        end
    end
    return true
end

function ActionHandlers.denounce(playerID, action, pPlayer, isLocalPlayer)
    if not action.target_player then
        ClaudeAI.Log("ERROR: denounce requires target_player")
        return false
    end

    local targetPlayerID = action.target_player
    ClaudeAI.Log("Denouncing player " .. targetPlayerID)

    if isLocalPlayer then
        -- Use UI context for denouncement
        ClaudeAI.RequestDiplomacyAction("denounce," .. targetPlayerID)
    else
        -- For AI players, try gameplay API
        local success, err = pcall(function()
            local pDiplomacy = pPlayer:GetDiplomacy()
            if pDiplomacy and pDiplomacy.DenouncePlayer then
                pDiplomacy:DenouncePlayer(targetPlayerID)
            end
        end)
        if not success then
            ClaudeAI.Log("ERROR: Failed to denounce: " .. tostring(err))
            return false
        end
    end
    return true
end

function ActionHandlers.make_peace(playerID, action, pPlayer, isLocalPlayer)
    if not action.target_player then
        ClaudeAI.Log("ERROR: make_peace requires target_player")
        return false
    end

    local targetPlayerID = action.target_player
    ClaudeAI.Log("Requesting peace with player " .. targetPlayerID)

    if isLocalPlayer then
        -- Use UI context to initiate peace session
        ClaudeAI.RequestDiplomacyAction("make_peace," .. targetPlayerID)
    else
        -- For AI players, use gameplay API
        local success, err = pcall(function()
            local pDiplomacy = pPlayer:GetDiplomacy()
            if pDiplomacy and pDiplomacy.MakePeaceWith then
                pDiplomacy:MakePeaceWith(targetPlayerID)
            end
        end)
        if not success then
            ClaudeAI.Log("ERROR: Failed to make peace: " .. tostring(err))
            return false
        end
    end
    return true
end

function ActionHandlers.diplomacy_respond(playerID, action, pPlayer, isLocalPlayer)
    if not action.target_player or not action.response then
        ClaudeAI.Log("ERROR: diplomacy_respond requires target_player and response")
        return false
    end

    local targetPlayerID = action.target_player
    local response = action.response  -- "POSITIVE", "NEGATIVE", or "RESPONSE_IGNORE"
    ClaudeAI.Log("Responding to diplomacy from player " .. targetPlayerID .. " with " .. response)

    if isLocalPlayer then
        ClaudeAI.RequestDiplomacyAction("respond," .. targetPlayerID .. "," .. response)
    end
    return true
end

function ActionHandlers.end_turn(playerID, action, pPlayer, isLocalPlayer)
    ClaudeAI.Log("End turn" .. (action.reason and (" - " .. action.reason) or ""))

    -- Clear tactical notes at end of turn (they're turn-specific)
    ClaudeAI.ClearTacticalNotes()

    -- For human players, first dismiss any blocking notifications and diplomacy, then end turn
    if isLocalPlayer then
        ClaudeAI.RequestDismissNotifications()
        ClaudeAI.RequestDiplomacyAction("dismiss")  -- Dismiss any pending diplomacy popups
        ClaudeAI.RequestEndTurn()
    end

    return true
end

-- ============================================================================
-- ACTION EXECUTION (Dispatcher)
-- ============================================================================

function ClaudeAI.ExecuteAction(playerID, action)
    if not action or not action.action then
        ClaudeAI.Log("No valid action to execute")
        return false
    end

    ClaudeAI.Log("Executing action: " .. action.action)

    if action.error then
        ClaudeAI.Log("Action contains error: " .. action.error)
        return false
    end

    local pPlayer = Players[playerID]
    if not pPlayer then return false end

    -- Check if this is the local (human) player - use Request APIs
    local isLocalPlayer = (Game.GetLocalPlayer() == playerID)

    -- Look up handler in dispatch table
    local handler = ActionHandlers[action.action]
    if handler then
        return handler(playerID, action, pPlayer, isLocalPlayer)
    else
        ClaudeAI.Log("Unknown action: " .. action.action)
        return false
    end
end

-- ============================================================================
-- MAIN AI TURN HANDLER (ASYNC VERSION)
-- ============================================================================

-- State for async processing
ClaudeAI.AsyncState = {
    isWaiting = false,        -- Are we waiting for a response?
    playerID = nil,           -- Which player we're processing for
    pollHandler = nil,        -- The event handler for polling
    pollCount = 0,            -- How many times we've polled
    startTime = 0,            -- When polling started (os.clock())
    timeoutSeconds = LIMITS.ASYNC_TIMEOUT_SECONDS,
}

-- Process the response from Claude (shared by sync and async paths)
function ClaudeAI.HandleResponse(playerID, actionJson)
    if actionJson then
        local previewLen = LIMITS.MAX_JSON_PREVIEW_LENGTH
        ClaudeAI.Log("Received response: " .. actionJson:sub(1, previewLen) .. (actionJson:len() > previewLen and "..." or ""))

        -- Parse the response (returns table with "actions" array)
        local response = ClaudeAI.DecodeJSON(actionJson)

        if response then
            -- Check for error response
            if response.error then
                ClaudeAI.Log("ERROR from Claude API: " .. response.error)
                return
            end

            -- Execute all actions in the array
            if response.actions and #response.actions > 0 then
                ClaudeAI.Log("Executing " .. #response.actions .. " actions...")

                -- SMART REORDERING: Move found_city actions before move_unit for same unit
                -- This handles the case where Claude mistakenly moves then founds
                local reorderedActions = {}
                local foundCityActions = {}
                local moveUnitIds = {}

                -- First pass: identify found_city and move_unit actions
                for i, action in ipairs(response.actions) do
                    if action.action == "found_city" and action.unit_id then
                        foundCityActions[action.unit_id] = action
                    elseif action.action == "move_unit" and action.unit_id then
                        moveUnitIds[action.unit_id] = true
                    end
                end

                -- Check if there's a settler being both moved and used to found
                local needsReorder = false
                for unitId, _ in pairs(foundCityActions) do
                    if moveUnitIds[unitId] then
                        ClaudeAI.Log("WARNING: Settler " .. unitId .. " has both move and found_city actions - reordering to found first")
                        needsReorder = true
                    end
                end

                -- Build reordered list if needed
                if needsReorder then
                    -- First add found_city actions for units that also have move
                    for unitId, action in pairs(foundCityActions) do
                        if moveUnitIds[unitId] then
                            table.insert(reorderedActions, action)
                        end
                    end
                    -- Then add all other actions except the found_city we already added
                    for i, action in ipairs(response.actions) do
                        local dominated = (action.action == "found_city" and action.unit_id and moveUnitIds[action.unit_id])
                        if not dominated then
                            -- Skip move_unit for settlers that we're founding with
                            if not (action.action == "move_unit" and action.unit_id and foundCityActions[action.unit_id]) then
                                table.insert(reorderedActions, action)
                            else
                                ClaudeAI.Log("Skipping move_unit for settler " .. action.unit_id .. " (founding city instead)")
                            end
                        end
                    end
                else
                    reorderedActions = response.actions
                end

                local successCount = 0
                local failCount = 0

                for i, action in ipairs(reorderedActions) do
                    ClaudeAI.Log("--- Action " .. i .. "/" .. #response.actions .. ": " .. (action.action or "unknown") .. " ---")

                    local success = ClaudeAI.ExecuteAction(playerID, action)
                    if success then
                        successCount = successCount + 1
                    else
                        failCount = failCount + 1
                    end

                    -- Stop processing if we hit end_turn
                    if action.action == "end_turn" then
                        ClaudeAI.Log("End turn action reached, stopping action processing")
                        break
                    end
                end

                ClaudeAI.Log("Action execution complete: " .. successCount .. " succeeded, " .. failCount .. " failed")
            else
                ClaudeAI.Log("WARNING: No actions in response")
            end
        else
            ClaudeAI.Log("ERROR: Failed to decode response")
        end
    else
        ClaudeAI.Log("No response from Claude API")
    end
end

-- Poll for async response
function ClaudeAI.PollForResponse()
    if not ClaudeAI.AsyncState.isWaiting then
        return
    end

    -- Check if async functions are available
    if not CheckClaudeAPIResponse then
        ClaudeAI.Log("ERROR: CheckClaudeAPIResponse not available!")
        ClaudeAI.StopPolling()
        return
    end

    -- Poll the C++ side
    local status, response = CheckClaudeAPIResponse()

    -- Handle "ready_long" status - response stored in Game property due to 512 byte limit
    if status == "ready_long" then
        ClaudeAI.Log("[ASYNC] Long response stored in Game property, retrieving...")
        if Game and Game.GetProperty then
            response = Game.GetProperty(PROPERTY_KEYS.LONG_RESPONSE)
            if response then
                ClaudeAI.Log("[ASYNC] Retrieved long response from Game property - length=" .. tostring(#response))
                -- Clear the property after reading
                Game.SetProperty(PROPERTY_KEYS.LONG_RESPONSE, "")
                status = "ready"  -- Treat as ready now
            else
                ClaudeAI.Log("[ASYNC] ERROR: Failed to retrieve long response from Game property")
                status = "error"
                response = "Failed to retrieve long response"
            end
        else
            ClaudeAI.Log("[ASYNC] ERROR: Game.GetProperty not available")
            status = "error"
            response = "Game.GetProperty not available"
        end
    end

    -- DEBUG: Log immediately what we received from C++
    if response and status == "ready" then
        ClaudeAI.Log("[ASYNC DEBUG] Raw response from C++ - length=" .. tostring(#response) .. " type=" .. type(response))
        ClaudeAI.Log("[ASYNC DEBUG] Last 50 chars: ..." .. response:sub(-50))
    end

    ClaudeAI.AsyncState.pollCount = ClaudeAI.AsyncState.pollCount + 1

    -- Log occasionally to show we're still polling
    local elapsedTime = os.clock() - ClaudeAI.AsyncState.startTime
    if ClaudeAI.AsyncState.pollCount % LIMITS.POLL_LOG_INTERVAL == 0 then
        ClaudeAI.Log("[ASYNC] Poll #" .. ClaudeAI.AsyncState.pollCount .. " - elapsed: " .. string.format("%.1f", elapsedTime) .. "s - status: " .. tostring(status))
    end

    if status == "pending" then
        -- Still waiting, check for timeout (time-based, not poll-count based)
        if elapsedTime >= ClaudeAI.AsyncState.timeoutSeconds then
            ClaudeAI.Log("[ASYNC] Timeout waiting for response after " .. string.format("%.1f", elapsedTime) .. " seconds (" .. ClaudeAI.AsyncState.pollCount .. " polls)")
            ClaudeAI.StopPolling()
            ClaudeAI.NotifyTurnEnded(ClaudeAI.AsyncState.playerID)
        end
        -- Keep polling
        return
    end

    -- Response received (ready, error, or idle)
    ClaudeAI.Log("[ASYNC] Response received with status: " .. tostring(status))

    local playerID = ClaudeAI.AsyncState.playerID
    ClaudeAI.StopPolling()

    if status == "ready" and response then
        ClaudeAI.HandleResponse(playerID, response)
    elseif status == "error" then
        ClaudeAI.Log("[ASYNC] Error from API: " .. tostring(response))
    else
        ClaudeAI.Log("[ASYNC] Unexpected status: " .. tostring(status))
    end

    -- Notify UI that turn is complete
    ClaudeAI.NotifyTurnEnded(playerID)
    ClaudeAI.Log("========================================")
    ClaudeAI.Log("Turn processing complete")
    ClaudeAI.Log("========================================")
end

-- Stop the polling loop
function ClaudeAI.StopPolling()
    ClaudeAI.AsyncState.isWaiting = false
    ClaudeAI.AsyncState.pollCount = 0

    -- Remove the event handler if it exists
    if ClaudeAI.AsyncState.pollHandler and Events.GameCoreEventPublishComplete then
        Events.GameCoreEventPublishComplete.Remove(ClaudeAI.AsyncState.pollHandler)
        ClaudeAI.AsyncState.pollHandler = nil
        ClaudeAI.Log("[ASYNC] Stopped polling")
    end
end

-- Start the async polling loop
function ClaudeAI.StartPolling(playerID)
    ClaudeAI.AsyncState.isWaiting = true
    ClaudeAI.AsyncState.playerID = playerID
    ClaudeAI.AsyncState.pollCount = 0
    ClaudeAI.AsyncState.startTime = os.clock()

    -- Create the poll handler
    ClaudeAI.AsyncState.pollHandler = function()
        ClaudeAI.PollForResponse()
    end

    -- Register for frequent updates
    if Events.GameCoreEventPublishComplete then
        Events.GameCoreEventPublishComplete.Add(ClaudeAI.AsyncState.pollHandler)
        ClaudeAI.Log("[ASYNC] Started polling for response")
    else
        ClaudeAI.Log("[ASYNC] ERROR: GameCoreEventPublishComplete not available!")
    end
end

function ClaudeAI.ProcessTurn(playerID)
    ClaudeAI.Log("========================================")
    ClaudeAI.Log("Processing turn for player " .. playerID)
    ClaudeAI.Log("========================================")

    -- TEMPORARILY DISABLED - May be causing crashes
    -- local isLocalPlayer = (Game.GetLocalPlayer() == playerID)
    -- if isLocalPlayer then
    --     ClaudeAI.RequestDismissNotifications()
    -- end

    -- Check if we're already waiting for a response
    if ClaudeAI.AsyncState.isWaiting then
        ClaudeAI.Log("Already waiting for async response, skipping")
        return
    end

    -- Check if async functions are available (preferred)
    local useAsync = StartClaudeAPIRequest ~= nil and CheckClaudeAPIResponse ~= nil

    if not useAsync then
        -- Fall back to blocking call if async not available
        if not SendGameStateToClaudeAPI then
            ClaudeAI.Log("ERROR: No Claude API functions available!")
            ClaudeAI.Log("Make sure version.dll is properly installed")
            ClaudeAI.NotifyThinking(false)
            return
        end
        ClaudeAI.Log("Using BLOCKING API (async not available)")
    else
        ClaudeAI.Log("Using ASYNC API (non-blocking)")
    end

    -- Get game state
    local gameStateJson = ClaudeAI.GetGameState(playerID)

    -- Notify UI that Claude is thinking
    ClaudeAI.NotifyThinking(true)

    if useAsync then
        -- ASYNC PATH: Start request and set up polling
        ClaudeAI.Log("Starting async request to Claude API...")

        local started = StartClaudeAPIRequest(gameStateJson)

        if started then
            ClaudeAI.Log("Async request started successfully")
            ClaudeAI.StartPolling(playerID)
            -- Return immediately - polling will handle the response
            return
        else
            ClaudeAI.Log("ERROR: Failed to start async request")
            ClaudeAI.NotifyTurnEnded(playerID)
            return
        end
    else
        -- BLOCKING PATH (legacy fallback)
        ClaudeAI.Log("Sending game state to Claude API (blocking)...")
        local actionJson = SendGameStateToClaudeAPI(gameStateJson)

        ClaudeAI.HandleResponse(playerID, actionJson)

        -- Notify UI that turn is complete
        ClaudeAI.NotifyTurnEnded(playerID)
        ClaudeAI.Log("========================================")
        ClaudeAI.Log("Turn processing complete (blocking)")
        ClaudeAI.Log("========================================")
    end
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

function ClaudeAI.OnPlayerTurnStarted(playerID)
    -- Check if Claude AI is enabled
    if not ClaudeAI.Config.enabled then
        return
    end

    -- Auto-detect local player if not set
    if ClaudeAI.Config.controlledPlayerID < 0 then
        ClaudeAI.Config.controlledPlayerID = ClaudeAI.FindLocalPlayer()
        if ClaudeAI.Config.controlledPlayerID >= 0 then
            ClaudeAI.Log("Auto-selected local player: " .. tostring(ClaudeAI.Config.controlledPlayerID))

            -- Notify UI about Claude's player (with pcall protection)
            local civName = "Unknown"
            local leaderName = "Unknown"
            if PlayerConfigurations and PlayerConfigurations[ClaudeAI.Config.controlledPlayerID] then
                pcall(function()
                    local config = PlayerConfigurations[ClaudeAI.Config.controlledPlayerID]
                    if config and config.GetCivilizationTypeName then
                        civName = config:GetCivilizationTypeName() or "Unknown"
                    end
                    if config and config.GetLeaderTypeName then
                        leaderName = config:GetLeaderTypeName() or "Unknown"
                    end
                end)
            end
            ClaudeAI.NotifyPlayerSet(ClaudeAI.Config.controlledPlayerID, civName, leaderName)
        end
    end

    -- Check if this is the player Claude should control
    if playerID ~= ClaudeAI.Config.controlledPlayerID then
        return
    end

    local pPlayer = Players[playerID]
    if not pPlayer then return end

    -- Notify UI that Claude's turn started
    local currentTurn = Game.GetCurrentGameTurn()
    ClaudeAI.NotifyTurnStarted(playerID, currentTurn)

    ClaudeAI.Log("Turn Started for Player " .. playerID .. " (Claude-controlled)")

    -- Only auto-process if configured to do so
    if ClaudeAI.Config.autoProcessTurn then
        ClaudeAI.ProcessTurn(playerID)
        -- Note: For async, NotifyTurnEnded is called after response is received
        -- For sync, we call it here
        if not ClaudeAI.AsyncState.isWaiting then
            ClaudeAI.NotifyTurnEnded(playerID)
        end
    else
        ClaudeAI.Log("Auto-process disabled - waiting for manual trigger")
    end
end

function ClaudeAI.OnLoadGameViewStateDone()
    print("[ClaudeAI] OnLoadGameViewStateDone triggered!")

    ClaudeAI.Log("Game view loaded - Claude will control local player")
    ClaudeAI.Log("Claude AI Enabled: " .. tostring(ClaudeAI.Config.enabled))

    -- Scan for existing wonders (important when loading a save game)
    ClaudeAI.ScanExistingWonders()

    -- Enable auto-dismiss diplomacy popups (first meeting, etc.) when Claude is playing
    ClaudeAI.SetAutoDismissDiplomacy(true)
    ClaudeAI.Log("Auto-dismiss diplomacy enabled")

    -- Debug: Dump available UnitOperationTypes
    ClaudeAI.Log("DEBUG: Checking available UnitOperationTypes...")
    if UnitOperationTypes then
        local count = 0
        for k, v in pairs(UnitOperationTypes) do
            count = count + 1
            -- Only log operation types related to actions we care about
            if type(k) == "string" and (k:find("FOUND") or k:find("MOVE") or k:find("ATTACK")) then
                ClaudeAI.Log("  UnitOperationTypes." .. k .. " = " .. tostring(v))
            end
        end
        ClaudeAI.Log("  Total UnitOperationTypes: " .. count)
    else
        ClaudeAI.Log("  WARNING: UnitOperationTypes is nil!")
    end

    -- Debug: Dump available UnitCommandTypes
    ClaudeAI.Log("DEBUG: Checking available UnitCommandTypes...")
    if UnitCommandTypes then
        local count = 0
        for k, v in pairs(UnitCommandTypes) do
            count = count + 1
            if type(k) == "string" and (k:find("FOUND") or k:find("MOVE") or k:find("ATTACK")) then
                ClaudeAI.Log("  UnitCommandTypes." .. k .. " = " .. tostring(v))
            end
        end
        ClaudeAI.Log("  Total UnitCommandTypes: " .. count)
    else
        ClaudeAI.Log("  WARNING: UnitCommandTypes is nil!")
    end

    -- Debug: Dump available UnitManager methods
    ClaudeAI.Log("DEBUG: Checking available UnitManager methods...")
    if UnitManager then
        for k, v in pairs(UnitManager) do
            if type(v) == "function" then
                ClaudeAI.Log("  UnitManager." .. tostring(k) .. " = function")
            end
        end
    else
        ClaudeAI.Log("  WARNING: UnitManager is nil!")
    end

    -- Debug: Dump available PlayerManager methods
    ClaudeAI.Log("DEBUG: Checking available PlayerManager methods...")
    if PlayerManager then
        for k, v in pairs(PlayerManager) do
            if type(v) == "function" then
                ClaudeAI.Log("  PlayerManager." .. tostring(k) .. " = function")
            end
        end
    else
        ClaudeAI.Log("  WARNING: PlayerManager is nil!")
    end

    -- Don't try to detect AI player here - PlayerManager isn't ready yet
    -- Detection will happen on first PlayerTurnStarted event

    -- Check if our C++ functions are available
    ClaudeAI.Log("Checking for Claude API functions...")
    if StartClaudeAPIRequest and CheckClaudeAPIResponse then
        ClaudeAI.Log("  [OK] ASYNC API available (StartClaudeAPIRequest, CheckClaudeAPIResponse)")
    else
        ClaudeAI.Log("  [--] ASYNC API not available")
    end

    if SendGameStateToClaudeAPI then
        ClaudeAI.Log("  [OK] BLOCKING API available (SendGameStateToClaudeAPI)")
    else
        ClaudeAI.Log("  [--] BLOCKING API not available")
    end

    if not StartClaudeAPIRequest and not SendGameStateToClaudeAPI then
        ClaudeAI.Log("WARNING: No Claude API functions available!")
        ClaudeAI.Log("Make sure version.dll is installed in the game directory")
    end

    -- Register PlayerTurnStarted handler here (late initialization)
    if Events.PlayerTurnStarted then
        Events.PlayerTurnStarted.Add(ClaudeAI.OnPlayerTurnStarted)
        print("[ClaudeAI] Registered PlayerTurnStarted handler")
    else
        print("[ClaudeAI] WARNING: Events.PlayerTurnStarted not available")
        -- Debug: List available events
        print("[ClaudeAI] DEBUG: Available events in Events table:")
        if Events then
            for key, value in pairs(Events) do
                print("[ClaudeAI] DEBUG: Events." .. tostring(key) .. " = " .. tostring(value))
            end
        end
        -- Try GameEvents instead
        if GameEvents and GameEvents.PlayerTurnStarted then
            GameEvents.PlayerTurnStarted.Add(ClaudeAI.OnPlayerTurnStarted)
            print("[ClaudeAI] Registered PlayerTurnStarted handler via GameEvents")
        end
    end
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

print("[ClaudeAI] Registering event handlers...")

-- Register event handlers
if Events.LoadGameViewStateDone then
    Events.LoadGameViewStateDone.Add(ClaudeAI.OnLoadGameViewStateDone)
    print("[ClaudeAI] Registered LoadGameViewStateDone handler")
else
    print("[ClaudeAI] WARNING: Events.LoadGameViewStateDone not available")
end

-- Register wonder tracking events
if Events.WonderCompleted then
    Events.WonderCompleted.Add(ClaudeAI.OnWonderCompleted)
    print("[ClaudeAI] Registered WonderCompleted handler")
end

if Events.BuildingAddedToMap then
    Events.BuildingAddedToMap.Add(ClaudeAI.OnBuildingAddedToMap)
    print("[ClaudeAI] Registered BuildingAddedToMap handler")
end

-- Also try GameEvents for wonder tracking
if GameEvents then
    if GameEvents.WonderCompleted then
        GameEvents.WonderCompleted.Add(ClaudeAI.OnWonderCompleted)
        print("[ClaudeAI] Registered GameEvents.WonderCompleted handler")
    end
    if GameEvents.BuildingConstructed then
        GameEvents.BuildingConstructed.Add(function(playerID, cityID, buildingIndex, plotX, plotY, bOriginalConstruction)
            -- Log extra info for mystery build tracking
            if playerID == ClaudeAI.Config.controlledPlayerID then
                local buildingName = "UNKNOWN"
                pcall(function()
                    if GameInfo.Buildings and GameInfo.Buildings[buildingIndex] then
                        buildingName = GameInfo.Buildings[buildingIndex].BuildingType or "UNKNOWN"
                    end
                end)
                print("[ClaudeAI] BuildingConstructed event: " .. buildingName .. " player=" .. playerID .. " city=" .. cityID .. " bOriginalConstruction=" .. tostring(bOriginalConstruction))
            end
            ClaudeAI.OnBuildingAddedToMap(plotX, plotY, buildingIndex, playerID, cityID, 100)
        end)
        print("[ClaudeAI] Registered GameEvents.BuildingConstructed handler")
    end
end

print("========================================")
print("[ClaudeAI] Mod initialization complete!")
print("[ClaudeAI] Will auto-detect local human player")
print("========================================")

-- [END OF REFACTORED FILE]
-- The old monolithic ExecuteAction (732 lines) has been replaced with:
-- 1. Local helper utilities: SafeCall, SafeGet, FindGameInfoByIndex, etc. (~50 lines)
-- 2. ActionHandlers dispatch table with 15 focused handler functions (~700 lines)
-- 3. New ExecuteAction dispatcher (~25 lines)
-- Total: Same functionality, better organization and maintainability
