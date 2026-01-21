-- ============================================================================
-- ClaudeIndicator.lua - UI Context Script for Claude AI Mod
-- Shows "Claude is thinking" indicator and handles UI-context-only operations
-- ============================================================================

print("========================================")
print("ClaudeIndicator: UI script loading...")
print("========================================")

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local PROPERTY_KEYS = {
    -- Requests from gameplay to UI
    REQUEST_END_TURN = "ClaudeAI_RequestEndTurn",
    REQUEST_RESEARCH = "ClaudeAI_RequestResearch",
    REQUEST_CIVIC = "ClaudeAI_RequestCivic",
    REQUEST_PRODUCTION = "ClaudeAI_RequestProduction",
    REQUEST_GOVERNMENT = "ClaudeAI_RequestGovernment",
    REQUEST_POLICY = "ClaudeAI_RequestPolicy",
    REQUEST_DIPLOMACY = "ClaudeAI_RequestDiplomacy",
    REQUEST_PLACE_DISTRICT = "ClaudeAI_RequestPlaceDistrict",
    REQUEST_DISMISS_NOTIFICATIONS = "ClaudeAI_DismissNotifications",

    -- Flags
    IS_THINKING = "ClaudeAI_IsThinking",
    AUTO_DISMISS_DIPLOMACY = "ClaudeAI_AutoDismissDiplomacy",
}

local EXPOSED_MEMBER_KEYS = {
    GOVERNMENT_INFO = "ClaudeAI_GovernmentInfo",
    CIVIC_PROGRESS = "ClaudeAI_CivicProgress",
    FOUND_CITY_REQUEST = "ClaudeAI_FoundCityRequest",
    FOUND_CITY_RESULT = "ClaudeAI_FoundCityResult",
    PRODUCTION_REQUEST = "ClaudeAI_ProductionRequest",
    PRODUCTION_RESULT = "ClaudeAI_ProductionResult",
    IS_THINKING = "ClaudeAI_IsThinking",
}

local MIN_SHOW_DURATION = 2  -- Minimum seconds to show thinking indicator

local WAR_TYPE_TO_SESSION = {
    SURPRISE = "DECLARE_SURPRISE_WAR",
    FORMAL = "DECLARE_FORMAL_WAR",
    HOLY = "DECLARE_HOLY_WAR",
    LIBERATION = "DECLARE_LIBERATION_WAR",
    RECONQUEST = "DECLARE_RECONQUEST_WAR",
    PROTECTORATE = "DECLARE_PROTECTORATE_WAR",
    COLONIAL = "DECLARE_COLONIAL_WAR",
    TERRITORIAL = "DECLARE_TERRITORIAL_WAR",
}

-- ============================================================================
-- STATE
-- All module state variables grouped here for clarity
-- ============================================================================

local State = {
    -- UI indicator state
    isShowingThinking = false,
    thinkingShowTime = 0,
    turnEnded = false,

    -- Player info
    claudePlayerID = -1,
    claudeCivName = "",

    -- Request tracking (to avoid duplicate processing)
    processedEndTurn = false,
    lastRequests = {
        research = "",
        civic = "",
        production = "",
        government = "",
        policy = "",
        diplomacy = "",
        districtPlacement = "",
        dismissNotification = 0,
    },

    -- Popup state
    popupsDisabled = false,

    -- Polling state
    pollCount = 0,
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

--- Safely execute a function with pcall and log errors
---@param context string Description of what operation is being performed
---@param fn function The function to execute
---@return boolean success, any result
local function SafeExecute(context, fn)
    local success, result = pcall(fn)
    if not success then
        print("[ClaudeIndicator] ERROR in " .. context .. ": " .. tostring(result))
    end
    return success, result
end

--- Log a message with the ClaudeIndicator prefix
---@param message string
local function Log(message)
    print("[ClaudeIndicator] " .. message)
end

--- Format a civilization/leader name for display
---@param rawName string Raw name like "CIVILIZATION_ROME"
---@param prefix string Prefix to remove like "CIVILIZATION_"
---@return string Formatted name
local function FormatDisplayName(rawName, prefix)
    if not rawName then return "Unknown" end
    local name = rawName:gsub(prefix, ""):gsub("_", " ")
    -- Title case
    return name:lower():gsub("^%l", string.upper):gsub(" %l", string.upper)
end

--- Simple JSON encoder for Lua tables
---@param tbl table The table to encode
---@return string JSON string
local function TableToJSON(tbl)
    if type(tbl) ~= "table" then
        if type(tbl) == "string" then
            -- Escape special characters
            local escaped = tbl:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
            return '"' .. escaped .. '"'
        elseif tbl == nil then
            return "null"
        else
            return tostring(tbl)
        end
    end

    -- Check if array or object (array has sequential integer keys starting at 1)
    local isArray = true
    local maxIndex = 0
    for k, _ in pairs(tbl) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
            isArray = false
            break
        end
        maxIndex = math.max(maxIndex, k)
    end
    isArray = isArray and maxIndex == #tbl

    local result = {}
    if isArray then
        for _, v in ipairs(tbl) do
            table.insert(result, TableToJSON(v))
        end
        return "[" .. table.concat(result, ",") .. "]"
    else
        for k, v in pairs(tbl) do
            local key = type(k) == "string" and k or tostring(k)
            table.insert(result, '"' .. key .. '":' .. TableToJSON(v))
        end
        return "{" .. table.concat(result, ",") .. "}"
    end
end

--- Get a Game property safely
---@param key string Property key
---@return any value
local function GetGameProperty(key)
    if Game and Game.GetProperty then
        return Game.GetProperty(key)
    end
    return nil
end

-- ============================================================================
-- UI CONTROL FUNCTIONS
-- ============================================================================

local function ShowThinkingIndicator(show)
    local thinkingPanel = ContextPtr:LookUpControl("ThinkingPanel")
    if thinkingPanel then
        thinkingPanel:SetHide(not show)
        State.isShowingThinking = show

        local pulseAnim = ContextPtr:LookUpControl("PulseAnim")
        if pulseAnim then
            if show then
                pulseAnim:SetToBeginning()
                pulseAnim:Play()
            else
                pulseAnim:Stop()
            end
        end

        if show then
            Log("Showing thinking indicator")
        end
    end
end

local function ShowStatusPanel(show)
    local statusPanel = ContextPtr:LookUpControl("StatusPanel")
    if statusPanel then
        statusPanel:SetHide(not show)
    end
end

local function UpdateStatusLabel(text)
    local statusLabel = ContextPtr:LookUpControl("StatusLabel")
    if statusLabel then
        statusLabel:SetText(text)
    end
end

-- ============================================================================
-- PLAYER INFO
-- ============================================================================

local function GetClaudePlayerInfo()
    -- Try local player first (Claude controls human player slot)
    if Game and Game.GetLocalPlayer then
        local localPlayerID = Game.GetLocalPlayer()
        if localPlayerID and localPlayerID >= 0 then
            local pConfig = PlayerConfigurations[localPlayerID]
            if pConfig then
                local civName = FormatDisplayName(pConfig:GetCivilizationTypeName(), "CIVILIZATION_")
                local leaderName = FormatDisplayName(pConfig:GetLeaderTypeName(), "LEADER_")
                return localPlayerID, civName, leaderName
            end
        end
    end

    -- Fallback: Check PlayerManager for human players
    if not PlayerManager then
        return nil, "PlayerManager not available"
    end

    local aliveMajors = PlayerManager.GetAliveMajors()
    if not aliveMajors then
        return nil, "No alive majors"
    end

    for _, playerObj in ipairs(aliveMajors) do
        if playerObj and playerObj:IsHuman() then
            local playerID = playerObj:GetID()
            local pConfig = PlayerConfigurations[playerID]
            if pConfig then
                local civName = FormatDisplayName(pConfig:GetCivilizationTypeName(), "CIVILIZATION_")
                local leaderName = FormatDisplayName(pConfig:GetLeaderTypeName(), "LEADER_")
                return playerID, civName, leaderName
            end
        end
    end

    return nil, "No local player found"
end

-- ============================================================================
-- POPUP SUPPRESSION
-- ============================================================================

local function DisableTechCivicPopups()
    if State.popupsDisabled then return end

    SafeExecute("DisableTechCivicPopups", function()
        if LuaEvents and LuaEvents.TutorialUIRoot_DisableTechAndCivicPopups then
            LuaEvents.TutorialUIRoot_DisableTechAndCivicPopups()
            State.popupsDisabled = true
            Log("Tech/Civic completion popups disabled")
        else
            Log("TutorialUIRoot_DisableTechAndCivicPopups not available")
        end
    end)
end

local function CloseChooserPanels()
    SafeExecute("CloseChooserPanels", function()
        if not LuaEvents then return end

        if LuaEvents.LaunchBar_CloseChoosers then
            LuaEvents.LaunchBar_CloseChoosers()
        end
        if LuaEvents.LaunchBar_CloseGovernmentPanel then
            LuaEvents.LaunchBar_CloseGovernmentPanel()
        end
        if LuaEvents.Government_CloseGovernment then
            LuaEvents.Government_CloseGovernment()
        end
    end)
end

-- ============================================================================
-- UI ACTION EXECUTORS
-- These functions execute UI-context-only operations
-- ============================================================================

local function ExecuteEndTurn()
    Log("Executing end turn request...")

    if UI and UI.RequestAction and ActionTypes and ActionTypes.ACTION_ENDTURN then
        SafeExecute("EndTurn", function()
            UI.RequestAction(ActionTypes.ACTION_ENDTURN)
        end)
        Log("Turn end requested successfully")
    else
        Log("WARNING: UI.RequestAction or ActionTypes.ACTION_ENDTURN not available")
    end
end

local function ExecuteResearch(playerID, techHash)
    Log("Executing research request - playerID=" .. tostring(playerID) .. ", techHash=" .. tostring(techHash))

    if UI and UI.RequestPlayerOperation and PlayerOperations then
        SafeExecute("Research", function()
            local tParameters = {
                [PlayerOperations.PARAM_TECH_TYPE] = techHash,
                [PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE,
            }
            UI.RequestPlayerOperation(playerID, PlayerOperations.RESEARCH, tParameters)
        end)
        Log("Research request sent successfully")
    else
        Log("WARNING: UI.RequestPlayerOperation or PlayerOperations not available")
    end
end

local function ExecuteCivic(playerID, civicHash)
    Log("Executing civic request - playerID=" .. tostring(playerID) .. ", civicHash=" .. tostring(civicHash))

    if UI and UI.RequestPlayerOperation and PlayerOperations then
        SafeExecute("Civic", function()
            local tParameters = {
                [PlayerOperations.PARAM_CIVIC_TYPE] = civicHash,
                [PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE,
            }
            UI.RequestPlayerOperation(playerID, PlayerOperations.PROGRESS_CIVIC, tParameters)
        end)
        Log("Civic request sent successfully")
    else
        Log("WARNING: UI.RequestPlayerOperation or PlayerOperations not available")
    end
end

local function ExecuteProduction(playerID, cityID, productionType, productionHash)
    Log("Executing production request - type=" .. tostring(productionType) .. ", hash=" .. tostring(productionHash))

    local pCity = CityManager and CityManager.GetCity and CityManager.GetCity(playerID, cityID)
    if not pCity then
        Log("ERROR: City not found: " .. tostring(cityID))
        return
    end

    SafeExecute("Production", function()
        local tParameters = {}

        local paramMap = {
            unit = CityOperationTypes.PARAM_UNIT_TYPE,
            building = CityOperationTypes.PARAM_BUILDING_TYPE,
            district = CityOperationTypes.PARAM_DISTRICT_TYPE,
            project = CityOperationTypes.PARAM_PROJECT_TYPE,
        }

        local paramKey = paramMap[productionType]
        if paramKey then
            tParameters[paramKey] = productionHash
        end

        if CityManager.RequestOperation and CityOperationTypes and CityOperationTypes.BUILD then
            CityManager.RequestOperation(pCity, CityOperationTypes.BUILD, tParameters)
            Log("Production request sent via RequestOperation")
        else
            Log("WARNING: CityManager.RequestOperation or CityOperationTypes.BUILD not available")
        end
    end)
end

local function ExecuteDistrictPlacement(playerID, cityID, districtHash, plotX, plotY)
    Log("Executing district placement - hash=" .. tostring(districtHash) .. " at (" .. tostring(plotX) .. "," .. tostring(plotY) .. ")")

    local pCity = CityManager and CityManager.GetCity and CityManager.GetCity(playerID, cityID)
    if not pCity then
        Log("ERROR: City not found: " .. tostring(cityID))
        return
    end

    SafeExecute("DistrictPlacement", function()
        local tParameters = {
            [CityOperationTypes.PARAM_DISTRICT_TYPE] = districtHash,
            [CityOperationTypes.PARAM_X] = plotX,
            [CityOperationTypes.PARAM_Y] = plotY,
        }

        if CityManager.RequestOperation and CityOperationTypes and CityOperationTypes.BUILD then
            CityManager.RequestOperation(pCity, CityOperationTypes.BUILD, tParameters)
            Log("District placement request sent at (" .. plotX .. "," .. plotY .. ")")
        else
            Log("WARNING: CityManager.RequestOperation or CityOperationTypes.BUILD not available")
        end
    end)
end

local function ExecuteGovernmentChange(playerID, governmentHash)
    Log("Executing government change - playerID=" .. tostring(playerID) .. ", hash=" .. tostring(governmentHash))

    SafeExecute("GovernmentChange", function()
        local pPlayer = Players[playerID]
        if not pPlayer then
            Log("ERROR: Player not found")
            return
        end

        local pPlayerCulture = pPlayer:GetCulture()
        if not pPlayerCulture then
            Log("ERROR: Player culture not found")
            return
        end

        if pPlayerCulture.CanChangeGovernmentAtAll and not pPlayerCulture:CanChangeGovernmentAtAll() then
            Log("Cannot change government at this time")
            return
        end

        if pPlayerCulture.RequestChangeGovernment then
            pPlayerCulture:RequestChangeGovernment(governmentHash)
            Log("Government change requested successfully")
        else
            Log("ERROR: RequestChangeGovernment not available")
        end
    end)
end

local function ExecutePolicyChange(playerID, policyData)
    Log("Executing policy change - playerID=" .. tostring(playerID))

    SafeExecute("PolicyChange", function()
        local pPlayer = Players[playerID]
        if not pPlayer then
            Log("ERROR: Player not found")
            return
        end

        local pPlayerCulture = pPlayer:GetCulture()
        if not pPlayerCulture then
            Log("ERROR: Player culture not found")
            return
        end

        local numSlots = pPlayerCulture:GetNumPolicySlots() or 0
        local clearList = {}
        local addList = {}

        -- Clear all slots first
        for slotIndex = 0, numSlots - 1 do
            table.insert(clearList, slotIndex)
        end

        -- Parse policy assignments (format: "slot:hash,slot:hash,...")
        for assignment in policyData:gmatch("[^,]+") do
            local slotStr, hashStr = assignment:match("(%d+):(%-?%d+)")
            if slotStr and hashStr then
                local slotIndex = tonumber(slotStr)
                local policyHash = tonumber(hashStr)
                if slotIndex and policyHash then
                    addList[slotIndex] = policyHash
                    Log("Adding policy hash " .. policyHash .. " to slot " .. slotIndex)
                end
            end
        end

        if pPlayerCulture.RequestPolicyChanges then
            pPlayerCulture:RequestPolicyChanges(clearList, addList)
            Log("Policy changes requested successfully")
        else
            Log("ERROR: RequestPolicyChanges not available")
        end
    end)
end

-- ============================================================================
-- DIPLOMACY HANDLERS
-- ============================================================================

local function DismissLeaderScreen()
    SafeExecute("DismissLeaderScreen", function()
        Log("Dismissing leader screen")
        if Events and Events.HideLeaderScreen then
            Events.HideLeaderScreen()
        end
    end)
end

local function CloseDiplomacySessions()
    SafeExecute("CloseDiplomacySessions", function()
        local localPlayerID = Game.GetLocalPlayer()
        if not localPlayerID or localPlayerID < 0 then return end
        if not DiplomacyManager then
            Log("DiplomacyManager not available")
            return
        end

        if Players and DiplomacyManager.FindOpenSessionID and DiplomacyManager.CloseSession then
            local pLocalPlayer = Players[localPlayerID]
            if pLocalPlayer then
                local pDiplomacy = pLocalPlayer:GetDiplomacy()
                if pDiplomacy then
                    for _, pOtherPlayer in ipairs(Players) do
                        local otherID = pOtherPlayer:GetID()
                        if otherID ~= localPlayerID and pOtherPlayer:IsAlive() then
                            local sessionID = DiplomacyManager.FindOpenSessionID(localPlayerID, otherID)
                            if sessionID and sessionID >= 0 then
                                Log("Closing diplomacy session " .. sessionID .. " with player " .. otherID)
                                DiplomacyManager.CloseSession(sessionID)
                            end
                        end
                    end
                end
            end
        end
    end)
end

local function RespondToDiplomacy(otherPlayerID, responseType)
    SafeExecute("RespondToDiplomacy", function()
        local localPlayerID = Game.GetLocalPlayer()
        if not localPlayerID or localPlayerID < 0 then
            Log("Invalid local player for diplomacy response")
            return
        end

        if not DiplomacyManager then
            Log("DiplomacyManager not available")
            return
        end

        local sessionID = DiplomacyManager.FindOpenSessionID(localPlayerID, otherPlayerID)
        if not sessionID or sessionID < 0 then
            Log("No open session with player " .. tostring(otherPlayerID))
            return
        end

        Log("Responding to session " .. sessionID .. " with " .. responseType)
        if DiplomacyManager.AddResponse then
            DiplomacyManager.AddResponse(sessionID, localPlayerID, responseType)
        end
    end)
end

local function ExecuteDiplomacyAction(actionStr)
    Log("Executing diplomacy action: " .. tostring(actionStr))

    SafeExecute("DiplomacyAction", function()
        local localPlayerID = Game.GetLocalPlayer()
        if not localPlayerID or localPlayerID < 0 then
            Log("Invalid local player")
            return
        end

        -- Parse action string: "action,otherPlayerID,param"
        local parts = {}
        for part in string.gmatch(actionStr, "([^,]+)") do
            table.insert(parts, part)
        end

        local action = parts[1]
        local otherPlayerID = tonumber(parts[2])

        if action == "dismiss" then
            DismissLeaderScreen()
            CloseDiplomacySessions()

        elseif action == "respond" and otherPlayerID then
            local responseType = parts[3] or "POSITIVE"
            RespondToDiplomacy(otherPlayerID, responseType)

        elseif action == "declare_war" and otherPlayerID then
            local warType = parts[3] or "SURPRISE"
            local sessionType = WAR_TYPE_TO_SESSION[warType] or "DECLARE_SURPRISE_WAR"

            if DiplomacyManager and DiplomacyManager.RequestSession then
                DiplomacyManager.RequestSession(localPlayerID, otherPlayerID, sessionType)
                Log("Declared " .. warType .. " war on player " .. otherPlayerID)
            else
                -- Fallback to PlayerOperations
                local parameters = {
                    [PlayerOperations.PARAM_PLAYER_ONE] = localPlayerID,
                    [PlayerOperations.PARAM_PLAYER_TWO] = otherPlayerID,
                }
                UI.RequestPlayerOperation(localPlayerID, PlayerOperations.DIPLOMACY_DECLARE_WAR, parameters)
                Log("Declared war on player " .. otherPlayerID .. " (fallback)")
            end

        elseif action == "denounce" and otherPlayerID then
            if DiplomacyManager and DiplomacyManager.RequestSession then
                DiplomacyManager.RequestSession(localPlayerID, otherPlayerID, "DENOUNCE")
                Log("Denounced player " .. otherPlayerID)
            end

        elseif action == "make_peace" and otherPlayerID then
            if DiplomacyManager and DiplomacyManager.RequestSession then
                DiplomacyManager.RequestSession(localPlayerID, otherPlayerID, "MAKE_PEACE")
                Log("Requested peace session with player " .. otherPlayerID)
            end
        end
    end)
end

-- ============================================================================
-- GOVERNMENT INFO GATHERING (UI Context only)
-- ============================================================================

local function GatherGovernmentInfo(playerID)
    Log("Gathering government info for player " .. tostring(playerID))

    local info = {
        currentGovernment = nil,
        availableGovernments = {},
        policySlots = {},
        availablePolicies = {},
    }

    SafeExecute("GatherGovernmentInfo", function()
        local pPlayer = Players[playerID]
        if not pPlayer then
            Log("GatherGovernmentInfo: Player not found")
            return
        end

        local pCulture = pPlayer:GetCulture()
        if not pCulture then
            Log("GatherGovernmentInfo: Player culture not found")
            return
        end

        -- Get current government
        if pCulture.GetCurrentGovernment and GameInfo.Governments then
            local currentGovIndex = pCulture:GetCurrentGovernment()
            if currentGovIndex and currentGovIndex >= 0 then
                for govInfo in GameInfo.Governments() do
                    if govInfo and govInfo.Index == currentGovIndex then
                        info.currentGovernment = govInfo.GovernmentType
                        Log("Current government: " .. info.currentGovernment)
                        break
                    end
                end
            end
        end

        -- Get available governments
        if pCulture.IsGovernmentUnlocked and GameInfo.Governments then
            for govInfo in GameInfo.Governments() do
                if govInfo and govInfo.GovernmentType then
                    local govHash = govInfo.Hash
                    if govHash and pCulture:IsGovernmentUnlocked(govHash) then
                        table.insert(info.availableGovernments, govInfo.GovernmentType)
                    end
                end
            end
            Log("Available governments: " .. #info.availableGovernments)
        end

        -- Get policy slots
        if pCulture.GetNumPolicySlots then
            local numSlots = pCulture:GetNumPolicySlots() or 0
            for slotIndex = 0, numSlots - 1 do
                local slotInfo = {
                    slotIndex = slotIndex,
                    slotType = "SLOT_WILDCARD",
                    currentPolicy = nil,
                }

                -- Get slot type
                if pCulture.GetSlotType and GameInfo.GovernmentSlots then
                    local slotTypeIndex = pCulture:GetSlotType(slotIndex)
                    for slotTypeInfo in GameInfo.GovernmentSlots() do
                        if slotTypeInfo and slotTypeInfo.Index == slotTypeIndex then
                            slotInfo.slotType = slotTypeInfo.GovernmentSlotType or "SLOT_WILDCARD"
                            break
                        end
                    end
                end

                -- Get current policy in slot
                if pCulture.GetSlotPolicy and GameInfo.Policies then
                    local policyIndex = pCulture:GetSlotPolicy(slotIndex)
                    if policyIndex and policyIndex >= 0 then
                        for policyInfo in GameInfo.Policies() do
                            if policyInfo and policyInfo.Index == policyIndex then
                                slotInfo.currentPolicy = policyInfo.PolicyType
                                break
                            end
                        end
                    end
                end

                table.insert(info.policySlots, slotInfo)
            end
            Log("Policy slots: " .. #info.policySlots)
        end

        -- Get available policies
        if pCulture.IsPolicyUnlocked and GameInfo.Policies then
            for policyInfo in GameInfo.Policies() do
                if policyInfo and policyInfo.PolicyType then
                    local policyIndex = policyInfo.Index
                    if policyIndex and pCulture:IsPolicyUnlocked(policyIndex) then
                        table.insert(info.availablePolicies, {
                            policy = policyInfo.PolicyType,
                            slotType = policyInfo.GovernmentSlotType or "SLOT_WILDCARD",
                        })
                    end
                end
            end
            Log("Available policies: " .. #info.availablePolicies)
        end
    end)

    return info
end

local function UpdateGovernmentInfoProperty(playerID)
    local info = GatherGovernmentInfo(playerID)
    local jsonStr = TableToJSON(info)

    -- Truncate if too long
    if #jsonStr > 4000 then
        Log("WARNING: Government info JSON truncated")
        jsonStr = jsonStr:sub(1, 4000)
    end

    if ExposedMembers then
        ExposedMembers[EXPOSED_MEMBER_KEYS.GOVERNMENT_INFO] = jsonStr
        Log("Stored government info via ExposedMembers (" .. #jsonStr .. " chars)")
    else
        Log("ERROR: ExposedMembers not available")
    end
end

local function GatherCivicProgressInfo(playerID)
    local info = {
        civicIndex = -1,
        civicProgress = 0,
        civicCost = 0,
        cultureYield = 0,
        turnsRemaining = 0,
    }

    SafeExecute("GatherCivicProgressInfo", function()
        local pPlayer = Players[playerID]
        if not pPlayer then return end

        local pCulture = pPlayer:GetCulture()
        if not pCulture then return end

        if pCulture.GetProgressingCivic then
            info.civicIndex = pCulture:GetProgressingCivic() or -1
        end

        if info.civicIndex >= 0 then
            -- Get progress (UI-only API)
            if pCulture.GetCivicProgress then
                info.civicProgress = pCulture:GetCivicProgress(info.civicIndex) or 0
            elseif pCulture.GetCurrentCivicProgress then
                info.civicProgress = pCulture:GetCurrentCivicProgress() or 0
            end

            -- Get cost from GameInfo
            for civicInfo in GameInfo.Civics() do
                if civicInfo.Index == info.civicIndex then
                    info.civicCost = civicInfo.Cost or 0
                    break
                end
            end

            -- Get culture yield (UI-only API)
            if pCulture.GetCultureYield then
                info.cultureYield = pCulture:GetCultureYield() or 0
            end

            -- Calculate turns remaining
            if info.cultureYield > 0 and info.civicCost > 0 then
                local remaining = info.civicCost - info.civicProgress
                info.turnsRemaining = remaining > 0 and math.ceil(remaining / info.cultureYield) or 0
            end

            Log("Civic progress: idx=" .. info.civicIndex ..
                  " progress=" .. info.civicProgress .. "/" .. info.civicCost ..
                  " culture/turn=" .. info.cultureYield .. " turns=" .. info.turnsRemaining)
        end
    end)

    return info
end

local function UpdateCivicProgressProperty(playerID)
    Log("UpdateCivicProgressProperty called for player " .. tostring(playerID))
    local info = GatherCivicProgressInfo(playerID)

    local infoStr = string.format("%d,%d,%d,%d,%d",
        info.civicIndex, info.civicProgress, info.civicCost, info.cultureYield, info.turnsRemaining)

    Log("Storing civic progress: " .. infoStr)
    if ExposedMembers then
        ExposedMembers[EXPOSED_MEMBER_KEYS.CIVIC_PROGRESS] = infoStr
    end
end

-- ============================================================================
-- REQUEST PROCESSING
-- Data-driven approach for handling Game property requests
-- ============================================================================

local RequestHandlers = {
    {
        key = PROPERTY_KEYS.REQUEST_DISMISS_NOTIFICATIONS,
        lastValue = function() return State.lastRequests.dismissNotification end,
        setLastValue = function(v) State.lastRequests.dismissNotification = v end,
        resetValue = 0,
        isNumeric = true,
        handler = function(value)
            if value == 1 then
                Log("Found dismiss notifications request")
                CloseChooserPanels()
            end
        end,
    },
    {
        key = PROPERTY_KEYS.REQUEST_END_TURN,
        lastValue = function() return State.processedEndTurn end,
        setLastValue = function(v) State.processedEndTurn = v end,
        resetValue = false,
        isNumeric = true,
        handler = function(value)
            if value == 1 and not State.processedEndTurn then
                State.processedEndTurn = true
                Log("Found end turn request")
                ExecuteEndTurn()
            end
        end,
    },
    {
        key = PROPERTY_KEYS.REQUEST_RESEARCH,
        lastValue = function() return State.lastRequests.research end,
        setLastValue = function(v) State.lastRequests.research = v end,
        resetValue = "",
        handler = function(value)
            Log("Found research request: " .. value)
            local playerID, techHash = value:match("([^,]+),([^,]+)")
            if playerID and techHash then
                ExecuteResearch(tonumber(playerID), tonumber(techHash))
            end
        end,
    },
    {
        key = PROPERTY_KEYS.REQUEST_CIVIC,
        lastValue = function() return State.lastRequests.civic end,
        setLastValue = function(v) State.lastRequests.civic = v end,
        resetValue = "",
        handler = function(value)
            Log("Found civic request: " .. value)
            local playerID, civicHash = value:match("([^,]+),([^,]+)")
            if playerID and civicHash then
                ExecuteCivic(tonumber(playerID), tonumber(civicHash))
            end
        end,
    },
    {
        key = PROPERTY_KEYS.REQUEST_PRODUCTION,
        lastValue = function() return State.lastRequests.production end,
        setLastValue = function(v) State.lastRequests.production = v end,
        resetValue = "",
        handler = function(value)
            Log("Found production request: " .. value)
            local playerID, cityID, productionType, productionHash = value:match("([^,]+),([^,]+),([^,]+),([^,]+)")
            if playerID and cityID and productionType and productionHash then
                ExecuteProduction(tonumber(playerID), tonumber(cityID), productionType, tonumber(productionHash))
            end
        end,
    },
    {
        key = PROPERTY_KEYS.REQUEST_GOVERNMENT,
        lastValue = function() return State.lastRequests.government end,
        setLastValue = function(v) State.lastRequests.government = v end,
        resetValue = "",
        handler = function(value)
            Log("Found government request: " .. value)
            local playerID, governmentHash = value:match("([^,]+),([^,]+)")
            if playerID and governmentHash then
                ExecuteGovernmentChange(tonumber(playerID), tonumber(governmentHash))
            end
        end,
    },
    {
        key = PROPERTY_KEYS.REQUEST_POLICY,
        lastValue = function() return State.lastRequests.policy end,
        setLastValue = function(v) State.lastRequests.policy = v end,
        resetValue = "",
        handler = function(value)
            Log("Found policy request: " .. value)
            local playerID = value:match("^([^,]+)")
            local policyData = value:match("^[^,]+,(.+)$")
            if playerID and policyData then
                ExecutePolicyChange(tonumber(playerID), policyData)
            end
        end,
    },
    {
        key = PROPERTY_KEYS.REQUEST_DIPLOMACY,
        lastValue = function() return State.lastRequests.diplomacy end,
        setLastValue = function(v) State.lastRequests.diplomacy = v end,
        resetValue = "",
        handler = function(value)
            Log("Found diplomacy request: " .. value)
            ExecuteDiplomacyAction(value)
        end,
    },
    {
        key = PROPERTY_KEYS.REQUEST_PLACE_DISTRICT,
        lastValue = function() return State.lastRequests.districtPlacement end,
        setLastValue = function(v) State.lastRequests.districtPlacement = v end,
        resetValue = "",
        handler = function(value)
            Log("Found district placement request: " .. value)
            local playerID, cityID, districtHash, plotX, plotY = value:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")
            if playerID and cityID and districtHash and plotX and plotY then
                ExecuteDistrictPlacement(tonumber(playerID), tonumber(cityID), tonumber(districtHash), tonumber(plotX), tonumber(plotY))
            end
        end,
    },
}

local function ProcessUIActionRequests()
    if not Game or not Game.GetProperty then return end

    for _, req in ipairs(RequestHandlers) do
        local value = GetGameProperty(req.key)
        local lastValue = req.lastValue()

        if req.isNumeric then
            -- Numeric request (like end turn, dismiss)
            if value and value ~= lastValue then
                req.handler(value)
                req.setLastValue(value)
            elseif not value or value == 0 then
                req.setLastValue(req.resetValue)
            end
        else
            -- String request
            if value and type(value) == "string" and value ~= "" and value ~= lastValue then
                req.setLastValue(value)
                req.handler(value)
            elseif not value or value == "" then
                req.setLastValue(req.resetValue)
            end
        end
    end
end

-- ============================================================================
-- EXPOSED MEMBERS BRIDGE (for city founding and legacy production)
-- ============================================================================

local function ProcessGameplayRequests()
    if not ExposedMembers then return end

    -- Process city founding requests
    local foundRequest = ExposedMembers[EXPOSED_MEMBER_KEYS.FOUND_CITY_REQUEST]
    if foundRequest then
        ExposedMembers[EXPOSED_MEMBER_KEYS.FOUND_CITY_REQUEST] = nil
        Log("Processing city founding request")

        if UnitManager and foundRequest.playerID and foundRequest.unitID then
            local pUnit = UnitManager.GetUnit(foundRequest.playerID, foundRequest.unitID)
            if pUnit and UnitManager.RequestOperation then
                local success = SafeExecute("FoundCity", function()
                    UnitManager.RequestOperation(pUnit, UnitOperationTypes.FOUND_CITY)
                end)
                ExposedMembers[EXPOSED_MEMBER_KEYS.FOUND_CITY_RESULT] = { success = success }
                if success then
                    Log("City founding request sent!")
                end
            end
        end
    end

    -- Process production requests (legacy path)
    local prodRequest = ExposedMembers[EXPOSED_MEMBER_KEYS.PRODUCTION_REQUEST]
    if prodRequest then
        ExposedMembers[EXPOSED_MEMBER_KEYS.PRODUCTION_REQUEST] = nil
        Log("Processing production request")

        if CityManager and prodRequest.playerID and prodRequest.cityID then
            local pCity = CityManager.GetCity(prodRequest.playerID, prodRequest.cityID)
            if pCity and CityManager.RequestCommand and CityCommandTypes and CityCommandTypes.PRODUCE then
                local tParameters = {}
                local typeMap = {
                    unit = "UnitType",
                    building = "BuildingType",
                    district = "DistrictType",
                    project = "ProjectType",
                }
                local paramName = typeMap[prodRequest.itemType]
                if paramName then
                    tParameters[paramName] = prodRequest.itemIndex
                end

                local success = SafeExecute("Production", function()
                    CityManager.RequestCommand(pCity, CityCommandTypes.PRODUCE, tParameters)
                end)
                if success then
                    Log("Production request sent!")
                    ExposedMembers[EXPOSED_MEMBER_KEYS.PRODUCTION_RESULT] = { success = true }
                end
            end
        end
    end
end

-- ============================================================================
-- POLLING AND EVENT HANDLERS
-- ============================================================================

local function CheckThinkingStatus()
    -- Process UI action requests first
    ProcessUIActionRequests()

    -- Check if we need to hide after minimum duration
    if State.isShowingThinking and State.turnEnded then
        local elapsed = os.clock() - State.thinkingShowTime
        if elapsed >= MIN_SHOW_DURATION then
            Log("Hiding indicator after delay (elapsed: " .. string.format("%.1f", elapsed) .. "s)")
            ShowThinkingIndicator(false)
            UpdateStatusLabel("[ICON_Capital] Claude: " .. State.claudeCivName)
            State.turnEnded = false
        end
    end

    -- Check Game property for thinking flag
    local gameThinking = GetGameProperty(PROPERTY_KEYS.IS_THINKING) == 1

    State.pollCount = State.pollCount + 1

    -- Show indicator if thinking
    if gameThinking and not State.isShowingThinking then
        Log("Claude is thinking - showing indicator (via poll)")
        ShowThinkingIndicator(true)
        UpdateStatusLabel("[ICON_TechBoosted] " .. State.claudeCivName .. " (Thinking...)")
        State.thinkingShowTime = os.clock()
        State.turnEnded = false

        DisableTechCivicPopups()

        if State.claudePlayerID >= 0 then
            UpdateGovernmentInfoProperty(State.claudePlayerID)
            UpdateCivicProgressProperty(State.claudePlayerID)
        end
    end

    -- Hide indicator when done thinking
    if not gameThinking and State.isShowingThinking then
        local elapsed = os.clock() - State.thinkingShowTime
        if elapsed >= MIN_SHOW_DURATION then
            Log("Thinking done, hiding indicator (via poll)")
            ShowThinkingIndicator(false)
            UpdateStatusLabel("[ICON_Capital] Claude: " .. State.claudeCivName)
        end
    end
end

local function OnClaudeTurnStarted(playerID, turn)
    Log("LuaEvent: Claude turn started - Player " .. tostring(playerID) .. ", Turn " .. tostring(turn))

    State.turnEnded = false
    DisableTechCivicPopups()
    CloseChooserPanels()
    UpdateGovernmentInfoProperty(playerID)
    UpdateCivicProgressProperty(playerID)

    if not State.isShowingThinking then
        ShowThinkingIndicator(true)
        UpdateStatusLabel("[ICON_TechBoosted] " .. State.claudeCivName .. " (Thinking...)")
        State.thinkingShowTime = os.clock()
        Log("Thinking indicator shown via LuaEvent")
    end
end

local function OnClaudeTurnEnded(playerID)
    Log("LuaEvent: Claude turn ended - Player " .. tostring(playerID))
    State.turnEnded = true

    local elapsed = os.clock() - State.thinkingShowTime
    if elapsed >= MIN_SHOW_DURATION then
        Log("Hiding indicator immediately (elapsed: " .. string.format("%.1f", elapsed) .. "s)")
        ShowThinkingIndicator(false)
        UpdateStatusLabel("[ICON_Capital] Claude: " .. State.claudeCivName)
        State.turnEnded = false
    else
        Log("Will hide after minimum duration (elapsed: " .. string.format("%.1f", elapsed) .. "s)")
    end
end

local function OnClaudePlayerSet(playerID, civName, leaderName)
    Log("LuaEvent: Player set - " .. tostring(civName))
    State.claudePlayerID = playerID
    State.claudeCivName = FormatDisplayName(civName, "CIVILIZATION_")
    UpdateStatusLabel("[ICON_Capital] Claude: " .. State.claudeCivName)
end

local function OnDiplomacyMeet(firstPlayer, secondPlayer)
    local localPlayerID = Game.GetLocalPlayer()
    if not localPlayerID or localPlayerID < 0 then return end

    if localPlayerID == firstPlayer or localPlayerID == secondPlayer then
        local otherPlayerID = (localPlayerID == firstPlayer) and secondPlayer or firstPlayer
        Log("First meeting detected with player " .. tostring(otherPlayerID))

        if GetGameProperty(PROPERTY_KEYS.AUTO_DISMISS_DIPLOMACY) == 1 then
            Log("Auto-dismissing first meeting popup")
            DismissLeaderScreen()
        end
    end
end

local function OnLoadGameViewStateDone()
    Log("Game view loaded")

    local playerID, civName, leaderName = GetClaudePlayerInfo()
    if playerID then
        State.claudePlayerID = playerID
        State.claudeCivName = civName
        Log("Claude is playing as: " .. civName .. " (Leader: " .. leaderName .. ") - Player " .. playerID)
        UpdateStatusLabel("[ICON_Capital] Claude: " .. civName)
    else
        State.claudeCivName = "Unknown"
        Log(tostring(civName))
        UpdateStatusLabel("[ICON_Capital] Claude AI")
    end

    ShowStatusPanel(true)
    ShowThinkingIndicator(false)
    DisableTechCivicPopups()

    if not ExposedMembers then
        ExposedMembers = {}
    end
    ExposedMembers[EXPOSED_MEMBER_KEYS.IS_THINKING] = false
end

local function OnPlayerTurnActivated(playerID, isFirstTime)
    CheckThinkingStatus()
    ProcessGameplayRequests()
end

local function OnPollTimer()
    CheckThinkingStatus()
    ProcessGameplayRequests()
end

local function OnShow()
    CheckThinkingStatus()
    ProcessGameplayRequests()
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local function Initialize()
    Log("Initializing UI...")

    ContextPtr:SetHide(false)

    -- Initialize ExposedMembers
    if not ExposedMembers then
        ExposedMembers = {}
    end
    ExposedMembers[EXPOSED_MEMBER_KEYS.IS_THINKING] = false
    ExposedMembers[EXPOSED_MEMBER_KEYS.FOUND_CITY_REQUEST] = nil
    ExposedMembers[EXPOSED_MEMBER_KEYS.PRODUCTION_REQUEST] = nil

    -- Register LuaEvents
    if LuaEvents then
        LuaEvents.ClaudeAI_TurnStarted.Add(OnClaudeTurnStarted)
        Log("Registered LuaEvents.ClaudeAI_TurnStarted")

        LuaEvents.ClaudeAI_TurnEnded.Add(OnClaudeTurnEnded)
        Log("Registered LuaEvents.ClaudeAI_TurnEnded")

        LuaEvents.ClaudeAI_PlayerSet.Add(OnClaudePlayerSet)
        Log("Registered LuaEvents.ClaudeAI_PlayerSet")

        Log("UI action requests will be processed via Game property polling")
    else
        Log("WARNING: LuaEvents not available")
    end

    -- Register game events
    if Events then
        if Events.LoadGameViewStateDone then
            Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone)
            Log("Registered LoadGameViewStateDone")
        end
        if Events.PlayerTurnActivated then
            Events.PlayerTurnActivated.Add(OnPlayerTurnActivated)
            Log("Registered PlayerTurnActivated")
        end
        if Events.GameCoreEventPublishComplete then
            Events.GameCoreEventPublishComplete.Add(OnPollTimer)
            Log("Registered polling via GameCoreEventPublishComplete")
        end
        if Events.DiplomacyMeet then
            Events.DiplomacyMeet.Add(OnDiplomacyMeet)
            Log("Registered DiplomacyMeet handler")
        end
        if Events.LeaderPopup then
            Events.LeaderPopup.Add(OnDiplomacyMeet)
            Log("Registered LeaderPopup handler")
        end
    end

    ShowThinkingIndicator(false)
    Log("UI initialization complete")
end

-- ============================================================================
-- CONTEXT HANDLERS
-- ============================================================================

ContextPtr:SetShowHandler(OnShow)

-- Initialize
Initialize()

print("========================================")
print("ClaudeIndicator: UI script loaded!")
print("========================================")
