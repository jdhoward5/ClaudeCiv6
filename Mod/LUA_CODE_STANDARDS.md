# Lua Code Standards for Claude AI Mod

**Purpose:** Establish consistent coding practices for Lua scripts in the Civ6 Claude AI mod.
**Last Updated:** January 18, 2026

---

## Table of Contents

1. [File Organization](#1-file-organization)
2. [Naming Conventions](#2-naming-conventions)
3. [Constants and Magic Values](#3-constants-and-magic-values)
4. [State Management](#4-state-management)
5. [Error Handling](#5-error-handling)
6. [Functions](#6-functions)
7. [Code Patterns](#7-code-patterns)
8. [Comments and Documentation](#8-comments-and-documentation)
9. [Civ6-Specific Patterns](#9-civ6-specific-patterns)
10. [Performance Considerations](#10-performance-considerations)

---

## 1. File Organization

### Section Order

Organize files in this order with clear section headers:

```lua
-- ============================================================================
-- FILE HEADER (description, purpose)
-- ============================================================================

-- ============================================================================
-- CONSTANTS
-- ============================================================================

-- ============================================================================
-- STATE
-- ============================================================================

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

-- ============================================================================
-- CORE LOGIC (grouped by feature)
-- ============================================================================

-- ============================================================================
-- EVENT HANDLERS
-- ============================================================================

-- ============================================================================
-- INITIALIZATION
-- ============================================================================
```

### Section Headers

Use consistent section headers with equal signs:

```lua
-- ============================================================================
-- SECTION NAME
-- Optional description of what this section contains
-- ============================================================================
```

### Subsection Headers

For grouping within sections, use shorter dividers:

```lua
-- ---------------------------------------------------------------------------
-- Subsection Name
-- ---------------------------------------------------------------------------
```

---

## 2. Naming Conventions

### Variables

| Type | Convention | Example |
|------|------------|---------|
| Local variables | camelCase | `playerID`, `civName`, `isEnabled` |
| Module state | camelCase in State table | `State.isShowingThinking` |
| Constants | UPPER_SNAKE_CASE | `MIN_SHOW_DURATION`, `MAX_RETRIES` |
| Private/internal | prefix with underscore | `_internalHelper` |
| Boolean variables | prefix with `is`, `has`, `can`, `should` | `isEnabled`, `hasLoaded`, `canAttack` |

### Functions

| Type | Convention | Example |
|------|------------|---------|
| Local functions | PascalCase | `ProcessRequests`, `UpdateStatusLabel` |
| Event handlers | `On` + EventName | `OnPlayerTurnStarted`, `OnLoadComplete` |
| Getters | `Get` + PropertyName | `GetPlayerInfo`, `GetGameProperty` |
| Setters | `Set` + PropertyName | `SetPlayerID`, `SetEnabled` |
| Boolean checkers | `Is`, `Has`, `Can`, `Should` | `IsValidPlayer`, `HasRequiredTech` |
| Executors/Actions | Verb + Noun | `ExecuteResearch`, `DismissPopup` |

### Constants Tables

Use descriptive names that indicate the category:

```lua
-- Good
local PROPERTY_KEYS = { ... }
local ERROR_MESSAGES = { ... }
local CONFIG = { ... }

-- Avoid
local KEYS = { ... }
local STRINGS = { ... }
local DATA = { ... }
```

---

## 3. Constants and Magic Values

### Extract All Magic Values

Never use literal strings or numbers inline. Extract to constants:

```lua
-- Bad
if Game.GetProperty("ClaudeAI_IsThinking") == 1 then
    -- wait at least 2 seconds
    if elapsed >= 2 then

-- Good
local PROPERTY_KEYS = {
    IS_THINKING = "ClaudeAI_IsThinking",
}
local MIN_SHOW_DURATION = 2

if Game.GetProperty(PROPERTY_KEYS.IS_THINKING) == 1 then
    if elapsed >= MIN_SHOW_DURATION then
```

### Group Related Constants

```lua
local PROPERTY_KEYS = {
    -- Requests from gameplay to UI
    REQUEST_END_TURN = "ClaudeAI_RequestEndTurn",
    REQUEST_RESEARCH = "ClaudeAI_RequestResearch",

    -- Flags
    IS_THINKING = "ClaudeAI_IsThinking",
}

local LIMITS = {
    MAX_JSON_LENGTH = 4000,
    MAX_RETRIES = 5,
    POLL_INTERVAL_MS = 100,
}
```

### Mapping Tables for Lookups

Use tables instead of if-else chains:

```lua
-- Bad
local function GetSessionType(warType)
    if warType == "FORMAL" then
        return "DECLARE_FORMAL_WAR"
    elseif warType == "HOLY" then
        return "DECLARE_HOLY_WAR"
    -- ... many more
    end
end

-- Good
local WAR_TYPE_TO_SESSION = {
    SURPRISE = "DECLARE_SURPRISE_WAR",
    FORMAL = "DECLARE_FORMAL_WAR",
    HOLY = "DECLARE_HOLY_WAR",
}

local function GetSessionType(warType)
    return WAR_TYPE_TO_SESSION[warType] or "DECLARE_SURPRISE_WAR"
end
```

---

## 4. State Management

### Centralize State in a Table

Group all module state in a single `State` table:

```lua
local State = {
    -- UI state
    isShowingThinking = false,
    thinkingShowTime = 0,

    -- Player info
    playerID = -1,
    civName = "",

    -- Request tracking
    lastRequests = {
        research = "",
        civic = "",
    },
}
```

### Benefits

- Easy to find all state variables
- Clear what state the module maintains
- Enables easy state reset if needed
- Prevents global namespace pollution

### Avoid Scattered Declarations

```lua
-- Bad (scattered throughout file)
local m_isEnabled = false
-- ... 200 lines later ...
local m_playerID = -1
-- ... 100 lines later ...
local m_lastRequest = ""

-- Good (centralized at top)
local State = {
    isEnabled = false,
    playerID = -1,
    lastRequest = "",
}
```

---

## 5. Error Handling

### Use pcall for External APIs

Wrap Civ6 API calls that may fail:

```lua
-- Bad
local value = pCulture:GetCurrentGovernment()  -- May crash if API unavailable

-- Good
local success, result = pcall(function()
    return pCulture:GetCurrentGovernment()
end)
if success then
    -- use result
end
```

### Create a SafeExecute Utility

```lua
local function SafeExecute(context, fn)
    local success, result = pcall(fn)
    if not success then
        print("[ModName] ERROR in " .. context .. ": " .. tostring(result))
    end
    return success, result
end

-- Usage
SafeExecute("GetGovernment", function()
    local gov = pCulture:GetCurrentGovernment()
    -- ... more code
end)
```

### Check API Availability

```lua
-- Bad
UI.RequestAction(ActionTypes.ACTION_ENDTURN)

-- Good
if UI and UI.RequestAction and ActionTypes and ActionTypes.ACTION_ENDTURN then
    UI.RequestAction(ActionTypes.ACTION_ENDTURN)
else
    Log("WARNING: UI.RequestAction not available")
end
```

### Validate Parameters Early

```lua
local function ProcessCity(playerID, cityID)
    -- Validate early, fail fast
    if not playerID or playerID < 0 then
        Log("ERROR: Invalid playerID")
        return false
    end

    local pCity = CityManager.GetCity(playerID, cityID)
    if not pCity then
        Log("ERROR: City not found: " .. tostring(cityID))
        return false
    end

    -- Main logic here...
    return true
end
```

---

## 6. Functions

### Keep Functions Small

Each function should do one thing. If a function exceeds ~50 lines, consider splitting it.

### Use Descriptive Names

```lua
-- Bad
function DoIt(p, c)
function Process(data)
function Handle(x)

-- Good
function ExecuteResearchRequest(playerID, techHash)
function ProcessUIActionRequests()
function HandleDiplomacyMeet(firstPlayer, secondPlayer)
```

### Document Complex Functions

Use LDoc-style annotations for complex functions:

```lua
--- Calculate the adjacency bonus for a district at a given plot
---@param pPlot userdata The plot object
---@param districtType string The district type (e.g., "DISTRICT_CAMPUS")
---@param playerID number The player ID
---@return number totalBonus The total adjacency bonus
---@return table sources Breakdown of bonus sources
local function CalculateDistrictAdjacency(pPlot, districtType, playerID)
    -- implementation
end
```

### Return Early for Guard Clauses

```lua
-- Bad
local function ProcessPlayer(playerID)
    if playerID and playerID >= 0 then
        local pPlayer = Players[playerID]
        if pPlayer then
            local pCulture = pPlayer:GetCulture()
            if pCulture then
                -- actual logic buried deep
            end
        end
    end
end

-- Good
local function ProcessPlayer(playerID)
    if not playerID or playerID < 0 then return end

    local pPlayer = Players[playerID]
    if not pPlayer then return end

    local pCulture = pPlayer:GetCulture()
    if not pCulture then return end

    -- actual logic at reasonable indent level
end
```

---

## 7. Code Patterns

### Data-Driven Design

For repetitive patterns, use data tables instead of repeated code:

```lua
-- Bad: Repetitive code for each request type
local function ProcessRequests()
    local researchReq = Game.GetProperty("ClaudeAI_RequestResearch")
    if researchReq and researchReq ~= lastResearch then
        lastResearch = researchReq
        ExecuteResearch(researchReq)
    elseif not researchReq then
        lastResearch = ""
    end

    local civicReq = Game.GetProperty("ClaudeAI_RequestCivic")
    if civicReq and civicReq ~= lastCivic then
        lastCivic = civicReq
        ExecuteCivic(civicReq)
    elseif not civicReq then
        lastCivic = ""
    end
    -- ... repeated 10 more times
end

-- Good: Data-driven approach
local RequestHandlers = {
    {
        key = "ClaudeAI_RequestResearch",
        lastValue = function() return State.lastRequests.research end,
        setLastValue = function(v) State.lastRequests.research = v end,
        resetValue = "",
        handler = function(value) ExecuteResearch(value) end,
    },
    {
        key = "ClaudeAI_RequestCivic",
        lastValue = function() return State.lastRequests.civic end,
        setLastValue = function(v) State.lastRequests.civic = v end,
        resetValue = "",
        handler = function(value) ExecuteCivic(value) end,
    },
}

local function ProcessRequests()
    for _, req in ipairs(RequestHandlers) do
        local value = Game.GetProperty(req.key)
        if value and value ~= "" and value ~= req.lastValue() then
            req.setLastValue(value)
            req.handler(value)
        elseif not value or value == "" then
            req.setLastValue(req.resetValue)
        end
    end
end
```

### Table Constructors for Parameters

```lua
-- Bad
local tParameters = {}
tParameters[CityOperationTypes.PARAM_DISTRICT_TYPE] = districtHash
tParameters[CityOperationTypes.PARAM_X] = plotX
tParameters[CityOperationTypes.PARAM_Y] = plotY

-- Good
local tParameters = {
    [CityOperationTypes.PARAM_DISTRICT_TYPE] = districtHash,
    [CityOperationTypes.PARAM_X] = plotX,
    [CityOperationTypes.PARAM_Y] = plotY,
}
```

### Avoid Deep Nesting

```lua
-- Bad (pyramid of doom)
if condition1 then
    if condition2 then
        if condition3 then
            if condition4 then
                -- actual code
            end
        end
    end
end

-- Good (early returns)
if not condition1 then return end
if not condition2 then return end
if not condition3 then return end
if not condition4 then return end
-- actual code
```

### Use Ternary-Style Expressions

```lua
-- Verbose
local displayName
if rawName then
    displayName = rawName
else
    displayName = "Unknown"
end

-- Concise
local displayName = rawName or "Unknown"

-- Conditional expression
local status = isEnabled and "Active" or "Inactive"
```

---

## 8. Comments and Documentation

### File Headers

Every file should have a header explaining its purpose:

```lua
-- ============================================================================
-- ClaudeIndicator.lua - UI Context Script for Claude AI Mod
-- Shows "Claude is thinking" indicator and handles UI-context-only operations
-- ============================================================================
```

### Comment Why, Not What

```lua
-- Bad (describes what code does - obvious from reading it)
-- Loop through all players
for _, player in ipairs(players) do

-- Good (explains why)
-- Check all players because city-states can also own units that might be in range
for _, player in ipairs(players) do
```

### Mark Workarounds and TODOs

```lua
-- WORKAROUND: pCulture:GetCultureYield() only works in UI context
-- We store the value via ExposedMembers for gameplay script to read

-- TODO: Add support for great person actions (Priority 2)

-- HACK: Civ6 fires this event twice sometimes, so we track last request
```

### Document API Quirks

```lua
-- NOTE: CityOperationTypes.PARAM_X/Y are required for district placement
-- but not documented in the official API reference

-- WARNING: Game.SetProperty() only works in Gameplay context, not UI context
```

---

## 9. Civ6-Specific Patterns

### Context Awareness

Always know which context your script runs in:

```lua
-- At top of file, document the context
-- This script runs in UI context (AddUserInterfaces in modinfo)
-- UI-only APIs: UI.RequestAction, pCulture:GetCurrentGovernment, etc.
-- Cannot use: Game.SetProperty (only works in Gameplay context)
```

### Cross-Context Communication

```lua
-- Gameplay to UI: Use Game.SetProperty (set in Gameplay, read in UI)
Game.SetProperty("ClaudeAI_RequestEndTurn", 1)

-- UI to Gameplay: Use ExposedMembers (writable from both contexts)
ExposedMembers.ClaudeAI_GovernmentInfo = jsonString

-- NEVER rely on LuaEvents crossing contexts (broken since Gathering Storm)
```

### Safe API Access Pattern

```lua
-- Pattern for safely accessing potentially unavailable APIs
local function SafeGetCity(playerID, cityID)
    if not CityManager or not CityManager.GetCity then
        return nil
    end
    return CityManager.GetCity(playerID, cityID)
end
```

### GameInfo Iteration

```lua
-- Iterate GameInfo tables safely
if GameInfo.Units then
    for unitInfo in GameInfo.Units() do
        if unitInfo and unitInfo.UnitType then
            -- process unit
        end
    end
end
```

---

## 10. Performance Considerations

### Cache Expensive Lookups

```lua
-- Bad (repeated lookups)
for i = 1, 100 do
    local pPlayer = Players[playerID]
    local pCities = pPlayer:GetCities()
    -- ...
end

-- Good (cache outside loop)
local pPlayer = Players[playerID]
local pCities = pPlayer:GetCities()
for i = 1, 100 do
    -- use cached values
end
```

### Avoid Creating Tables in Loops

```lua
-- Bad (creates new table each iteration)
for _, unit in ipairs(units) do
    local info = {
        id = unit:GetID(),
        type = unit:GetType(),
    }
    table.insert(results, info)
end

-- Better for hot paths (reuse table)
local info = {}
for _, unit in ipairs(units) do
    info.id = unit:GetID()
    info.type = unit:GetType()
    -- process info immediately rather than storing
end
```

### Limit Logging in Hot Paths

```lua
-- Bad (logs every poll, which happens every frame)
local function OnPollTimer()
    print("[Mod] Polling...")  -- Spams log file
end

-- Good (log only significant events)
local function OnPollTimer()
    -- No logging here
    if stateChanged then
        print("[Mod] State changed to: " .. newState)
    end
end
```

### Use Local Variables

```lua
-- Bad (global lookup each time)
for i = 1, 1000 do
    table.insert(results, value)
end

-- Good (local reference)
local insert = table.insert
for i = 1, 1000 do
    insert(results, value)
end
```

---

## Quick Reference Checklist

Before committing code, verify:

- [ ] All magic strings/numbers extracted to constants
- [ ] State variables centralized in State table
- [ ] Civ6 API calls wrapped in pcall or SafeExecute
- [ ] Functions have descriptive names and single responsibility
- [ ] No deep nesting (use early returns)
- [ ] Comments explain "why" not "what"
- [ ] File has clear section organization
- [ ] No logging in hot paths (polling, per-frame)
- [ ] Context documented (UI vs Gameplay)
- [ ] Cross-context communication uses correct method

---

## Examples

### Good File Structure Example

See `ClaudeIndicator.lua` for a well-organized file following these standards.

### Bad Patterns to Avoid

```lua
-- Scattered state
local x = 1
function foo() end
local y = 2
function bar() end
local z = 3

-- Magic values
if Game.GetProperty("ClaudeAI_IsThinking") == 1 then
    if elapsed >= 2 then

-- Deep nesting
if a then
    if b then
        if c then
            if d then

-- Repetitive code that should be data-driven
if type == "unit" then
    params[PARAM_UNIT] = hash
elseif type == "building" then
    params[PARAM_BUILDING] = hash
elseif type == "district" then
    params[PARAM_DISTRICT] = hash
-- ... etc
```
