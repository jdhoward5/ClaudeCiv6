-- ClaudeAI_SetupUI.lua
-- Frontend UI for selecting which player Claude AI controls
-- This runs in the game setup / staging room

print("========================================")
print("Claude AI Setup UI Loading...")
print("========================================")

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local CLAUDE_AI_ENABLED_KEY = "CLAUDE_AI_ENABLED"
local CLAUDE_AI_PLAYER_KEY = "CLAUDE_AI_PLAYER_ID"

-- ============================================================================
-- LOCAL STATE
-- ============================================================================

local m_isEnabled = false
local m_selectedPlayerID = -1
local m_playerEntries = {}

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

local function SaveSettings()
    -- Store in GameConfiguration so gameplay script can read it
    if GameConfiguration and GameConfiguration.SetValue then
        GameConfiguration.SetValue(CLAUDE_AI_ENABLED_KEY, m_isEnabled and 1 or 0)
        GameConfiguration.SetValue(CLAUDE_AI_PLAYER_KEY, m_selectedPlayerID)
        print("[ClaudeAI Setup] Saved: Enabled=" .. tostring(m_isEnabled) .. ", PlayerID=" .. tostring(m_selectedPlayerID))
    else
        print("[ClaudeAI Setup] WARNING: GameConfiguration not available")
    end
end

local function LoadSettings()
    -- Load from GameConfiguration
    if GameConfiguration and GameConfiguration.GetValue then
        local enabled = GameConfiguration.GetValue(CLAUDE_AI_ENABLED_KEY)
        local playerID = GameConfiguration.GetValue(CLAUDE_AI_PLAYER_KEY)

        m_isEnabled = (enabled == 1)
        m_selectedPlayerID = playerID or -1

        print("[ClaudeAI Setup] Loaded: Enabled=" .. tostring(m_isEnabled) .. ", PlayerID=" .. tostring(m_selectedPlayerID))
    end
end

-- ============================================================================
-- PLAYER LIST POPULATION
-- ============================================================================

local function PopulatePlayerList()
    local pullDown = ContextPtr:LookUpControl("PlayerPullDown")
    if not pullDown then
        print("[ClaudeAI Setup] ERROR: PlayerPullDown not found")
        return
    end

    pullDown:ClearEntries()
    m_playerEntries = {}

    -- Add "Disabled" option
    local disabledEntry = {}
    pullDown:BuildEntry("InstanceOne", disabledEntry)
    disabledEntry.Button:SetText(Locale.Lookup("LOC_CLAUDE_AI_DISABLED"))
    disabledEntry.Button:SetVoid1(-1)
    table.insert(m_playerEntries, {id = -1, entry = disabledEntry})

    -- Get player count from game configuration
    local playerCount = 0
    if GameConfiguration and GameConfiguration.GetParticipatingPlayerCount then
        playerCount = GameConfiguration.GetParticipatingPlayerCount()
    elseif MapConfiguration and MapConfiguration.GetMaxMajorPlayers then
        playerCount = MapConfiguration.GetMaxMajorPlayers()
    else
        playerCount = 8  -- Default fallback
    end

    print("[ClaudeAI Setup] Player count: " .. tostring(playerCount))

    -- Add entries for each potential AI player slot (skip slot 0, usually human)
    for i = 1, playerCount - 1 do
        local playerConfig = PlayerConfigurations[i]
        local entryText = ""

        if playerConfig then
            local civName = playerConfig:GetCivilizationTypeName()
            local leaderName = playerConfig:GetLeaderTypeName()
            local slotStatus = playerConfig:GetSlotStatus()

            -- Only show AI slots (SlotStatus 1 = AI, 3 = AI)
            -- SlotStatus: 0=None, 1=AI, 2=Human, 3=AI (closed?), etc.
            if slotStatus == 1 or slotStatus == 3 then
                if civName and civName ~= "" then
                    -- Clean up the civilization name for display
                    local displayName = civName:gsub("CIVILIZATION_", "")
                    displayName = displayName:gsub("_", " ")
                    entryText = "Player " .. i .. " - " .. displayName
                else
                    entryText = "Player " .. i .. " (AI)"
                end
            else
                entryText = "Player " .. i
            end
        else
            entryText = "Player " .. i
        end

        local entry = {}
        pullDown:BuildEntry("InstanceOne", entry)
        entry.Button:SetText(entryText)
        entry.Button:SetVoid1(i)
        table.insert(m_playerEntries, {id = i, entry = entry})
    end

    pullDown:CalculateInternals()

    -- Set initial selection
    local found = false
    for _, playerEntry in ipairs(m_playerEntries) do
        if playerEntry.id == m_selectedPlayerID then
            pullDown:GetButton():SetText(playerEntry.entry.Button:GetText())
            found = true
            break
        end
    end

    if not found then
        -- Default to disabled
        m_selectedPlayerID = -1
        pullDown:GetButton():SetText(Locale.Lookup("LOC_CLAUDE_AI_DISABLED"))
    end
end

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

local function OnEnableCheckboxChanged(isChecked)
    m_isEnabled = isChecked
    print("[ClaudeAI Setup] Enable changed: " .. tostring(m_isEnabled))

    -- Show/hide player selection based on enabled state
    local container = ContextPtr:LookUpControl("PlayerSelectContainer")
    if container then
        container:SetHide(not m_isEnabled)
    end

    SaveSettings()
end

local function OnPlayerSelected(playerID)
    m_selectedPlayerID = playerID
    print("[ClaudeAI Setup] Player selected: " .. tostring(playerID))

    -- Update the pulldown button text
    local pullDown = ContextPtr:LookUpControl("PlayerPullDown")
    if pullDown then
        for _, playerEntry in ipairs(m_playerEntries) do
            if playerEntry.id == playerID then
                pullDown:GetButton():SetText(playerEntry.entry.Button:GetText())
                break
            end
        end
    end

    SaveSettings()
end

local m_isDirty = false

local function OnGameConfigurationChanged()
    -- Mark dirty so next OnShow rebuilds the list
    m_isDirty = true
end

-- ============================================================================
-- INITIALIZATION
-- ============================================================================

local function Initialize()
    print("[ClaudeAI Setup] Initializing...")

    -- Load saved settings
    LoadSettings()

    -- Set up checkbox
    local checkbox = ContextPtr:LookUpControl("EnableCheckbox")
    if checkbox then
        checkbox:SetSelected(m_isEnabled)
        checkbox:RegisterCallback(Mouse.eLClick, function()
            local isChecked = not checkbox:IsSelected()
            checkbox:SetSelected(isChecked)
            OnEnableCheckboxChanged(isChecked)
        end)
    else
        print("[ClaudeAI Setup] WARNING: EnableCheckbox not found")
    end

    -- Set up pulldown
    local pullDown = ContextPtr:LookUpControl("PlayerPullDown")
    if pullDown then
        pullDown:RegisterSelectionCallback(OnPlayerSelected)
    else
        print("[ClaudeAI Setup] WARNING: PlayerPullDown not found")
    end

    -- Initial player list population
    PopulatePlayerList()

    -- Update visibility of player selection based on enabled state
    local container = ContextPtr:LookUpControl("PlayerSelectContainer")
    if container then
        container:SetHide(not m_isEnabled)
    end

    -- Listen for game configuration changes via appropriate events
    if Events.PlayerInfoChanged then
        Events.PlayerInfoChanged.Add(OnGameConfigurationChanged)
    end
    if Events.GameConfigChanged then
        Events.GameConfigChanged.Add(OnGameConfigurationChanged)
    end
    if Events.MultiplayerGameParameterUpdated then
        Events.MultiplayerGameParameterUpdated.Add(OnGameConfigurationChanged)
    end

    print("[ClaudeAI Setup] Initialization complete")
    print("========================================")
end

-- ============================================================================
-- CONTEXT HANDLERS
-- ============================================================================

function OnShow()
    print("[ClaudeAI Setup] OnShow")
    if m_isDirty then
        PopulatePlayerList()
        m_isDirty = false
    end
end

function OnHide()
    print("[ClaudeAI Setup] OnHide")
end

-- Register context handlers
ContextPtr:SetShowHandler(OnShow)
ContextPtr:SetHideHandler(OnHide)

-- Cleanup event handlers on context destruction
ContextPtr:SetShutdownHandler(function()
    if Events.PlayerInfoChanged then
        Events.PlayerInfoChanged.Remove(OnGameConfigurationChanged)
    end
    if Events.GameConfigChanged then
        Events.GameConfigChanged.Remove(OnGameConfigurationChanged)
    end
    if Events.MultiplayerGameParameterUpdated then
        Events.MultiplayerGameParameterUpdated.Remove(OnGameConfigurationChanged)
    end
end)

-- Initialize on load
Initialize()
