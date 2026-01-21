# Civilization VI Lua Context Reference

## Overview

Civ6 has **two separate Lua contexts** that run on different threads:
- **Gameplay Context** - Runs game logic, has direct access to game state
- **UI Context** - Runs user interface, uses cached data

Many APIs only work in one context. Calling a UI-only API from Gameplay (or vice versa) will either fail silently, return nil, or crash.

---

## Cross-Context Communication

### Game:SetProperty / Game:GetProperty

| Method | Gameplay Context | UI Context |
|--------|-----------------|------------|
| `Game:SetProperty(key, value)` | **YES** | **NO** |
| `Game:GetProperty(key)` | **YES** | **YES** |
| `Player:SetProperty(key, value)` | **YES** | **NO** |
| `Player:GetProperty(key)` | **YES** | **YES** |
| `City:SetProperty(key, value)` | **YES** | **NO** |
| `Unit:SetProperty(key, value)` | **YES** | **NO** |
| `Plot:SetProperty(key, value)` | **YES** | **NO** |

**Key Points:**
- Properties persist in save files
- Use unique keys to avoid conflicts with other mods
- Can store numbers, strings, booleans, and Lua tables
- Must use colon syntax: `Game:SetProperty()` not `Game.SetProperty()`

**Source:** [Sukritact's Modding Knowledge Base](https://sukritact.github.io/Civilization-VI-Modding-Knowledge-Base/About_Get-SetProperty)

### ExposedMembers

`ExposedMembers` is a global table **shared between all contexts**. This is the primary way to share data and functions between UI and Gameplay scripts.

```lua
-- UI Context: Define and expose a function
function MyMod_GetGovernment(playerID)
    local pPlayer = Players[playerID]
    return pPlayer:GetCulture():GetCurrentGovernment()
end
ExposedMembers.MyMod = ExposedMembers.MyMod or {}
ExposedMembers.MyMod.GetGovernment = MyMod_GetGovernment

-- Gameplay Context: Call the exposed function
local government = ExposedMembers.MyMod.GetGovernment(playerID)
```

**Important:** When passing game objects between contexts, the object doesn't gain the methods of the target context. Always pass primitive IDs (playerID, cityID, unitID) instead of objects, then retrieve the object in the target context.

### LuaEvents

**WARNING:** Since Gathering Storm, LuaEvents **no longer cross contexts**. A LuaEvent fired in UI context can only be received by UI scripts. A LuaEvent fired in Gameplay context can only be received by Gameplay scripts.

Use `ExposedMembers` or `Game:SetProperty/GetProperty` polling instead.

**Source:** [CivFanatics Forums](https://forums.civfanatics.com/threads/trying-to-understand-context-switching-b-t-gameplayscripts-and-ui-can-it-be-mixed.657998/)

---

## Context-Specific APIs

### UI Context Only

These APIs **only work in UI context** and will fail/crash in Gameplay scripts:

| API | Notes |
|-----|-------|
| `PlayerCulture:GetCurrentGovernment()` | Returns current government index |
| `PlayerCulture:IsGovernmentUnlocked(hash)` | Check if government is available |
| `PlayerCulture:GetNumPolicySlots()` | Get number of policy slots |
| `PlayerCulture:GetSlotPolicy(slotIndex)` | Get policy in slot |
| `PlayerCulture:IsPolicyUnlocked(index)` | Check if policy is available |
| `PlayerCulture:CanProgress(civicIndex)` | Check if civic can be researched |
| `PlayerCulture:RequestChangeGovernment()` | Request government change |
| `PlayerCulture:RequestPolicyChanges()` | Request policy changes |
| `UI.RequestAction()` | Request UI actions (end turn, etc.) |
| `UI.RequestPlayerOperation()` | Request player operations |
| `CityManager.RequestOperation()` | Request city operations |
| `UnitManager.RequestOperation()` | Request unit operations |
| `City:GetCulture():GetCultureYield()` | Culture yield accessors |

### Gameplay Context Only

These APIs **only work in Gameplay context**:

| API | Notes |
|-----|-------|
| `Game:SetProperty()` | Store persistent data |
| `Player:SetProperty()` | Store player-specific data |
| `City:SetProperty()` | Store city-specific data |
| `Unit:SetProperty()` | Store unit-specific data |
| `Plot:SetProperty()` | Store plot-specific data |
| `WorldBuilder.CityManager:Create()` | Create cities programmatically |
| `UnitManager.MoveUnit()` | Move units directly |

### Both Contexts

These APIs work in **both contexts**:

| API | Notes |
|-----|-------|
| `Game:GetProperty()` | Read persistent data |
| `Player:GetProperty()` | Read player-specific data |
| `Players[playerID]` | Get player object |
| `PlayerManager.GetAliveMajors()` | Get alive major civs |
| `Game.GetCurrentGameTurn()` | Get current turn |
| `GameInfo.*` | Database tables (Civics, Techs, etc.) |
| `PlayerCulture:HasCivic(index)` | Check if civic is completed |
| `PlayerCulture:GetProgressingCivic()` | Get current civic being researched |
| `PlayerTechs:HasTech(index)` | Check if tech is completed |
| `PlayerTechs:GetResearchingTech()` | Get current tech being researched |

---

## Common Patterns for ClaudeAI Mod

### Pattern 1: UI Gathers Data, Gameplay Reads It

For data that can only be gathered in UI context (like government info):

```lua
-- UI Context (ClaudeIndicator.lua)
function GatherGovernmentInfo(playerID)
    local pPlayer = Players[playerID]
    local pCulture = pPlayer:GetCulture()
    local govIndex = pCulture:GetCurrentGovernment()  -- UI-only API
    -- ... gather more data ...
    return info
end

-- Store in ExposedMembers (writable from UI)
ExposedMembers.ClaudeAI_GovernmentInfo = jsonString

-- Gameplay Context (ClaudeAI.lua)
local info = ExposedMembers.ClaudeAI_GovernmentInfo
```

### Pattern 2: Gameplay Requests, UI Executes

For operations that require UI context (like ending turn, setting research):

```lua
-- Gameplay Context: Set a request flag
Game:SetProperty("ClaudeAI_RequestEndTurn", 1)

-- UI Context: Poll for requests and execute
local request = Game:GetProperty("ClaudeAI_RequestEndTurn")
if request == 1 then
    UI.RequestAction(ActionTypes.ACTION_ENDTURN)
end
```

### Pattern 3: Timing Coordination

UI context runs on a different thread. To ensure data is ready:

```lua
-- Gameplay: Signal that we need data
Game:SetProperty("ClaudeAI_IsThinking", 1)

-- UI: When thinking flag detected, gather data
if Game:GetProperty("ClaudeAI_IsThinking") == 1 then
    -- Gather UI-only data now
    ExposedMembers.ClaudeAI_GovernmentInfo = GatherGovernmentInfo(playerID)
end

-- Gameplay: Read the data (may need to wait/poll)
local info = ExposedMembers.ClaudeAI_GovernmentInfo
```

---

## Debugging Tips

1. **Check which context your script runs in:**
   - `AddGameplayScripts` = Gameplay context
   - `AddUserInterfaces` = UI context

2. **If an API returns nil unexpectedly:** You're probably calling a UI-only API from Gameplay (or vice versa)

3. **If the game crashes on a PlayerCulture call:** PlayerCulture methods for governments/policies are UI-only

4. **If LuaEvents aren't received:** They don't cross contexts since Gathering Storm. Use ExposedMembers or Game properties instead.

5. **If Game:SetProperty doesn't work:** You're in UI context. Use ExposedMembers instead.

---

## References

- [Sukritact's Modding Knowledge Base](https://sukritact.github.io/Civilization-VI-Modding-Knowledge-Base/)
- [CivFanatics - Context Switching](https://forums.civfanatics.com/threads/trying-to-understand-context-switching-b-t-gameplayscripts-and-ui-can-it-be-mixed.657998/)
- [CivFanatics - LeeS' Modding Guide](https://forums.civfanatics.com/threads/lees-civilization-6-modding-guide.644687/)
- [Civ6 Modding Wiki](https://jonathanturnock.github.io/civ-vi-modding/)
