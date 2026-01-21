# Civilization VI Claude AI Integration

## Quick Start

**Status:** Beta - Claude is actively playing Civ6 (Phases 1-7 complete)

**Key Files:**
| File | Purpose |
|------|---------|
| `system_prompt.txt` | Claude's instructions (edit without rebuild, uses `{CIV_NAME}`, `{LEADER_NAME}`) |
| `ClaudeAI.lua` | Main gameplay logic (~3000 lines) |
| `ClaudeIndicator.lua` | UI context operations (~1300 lines) |
| `LUA_CONTEXT_REFERENCE.md` | UI vs Gameplay context APIs |
| `LUA_CODE_STANDARDS.md` | Lua coding conventions |
| `CPP_CODE_STANDARDS.md` | C++ coding conventions |
| `TODO_ACTIONS.md` | Action implementation tracking |

**Key Paths:**
| Purpose | Path |
|---------|------|
| DLL Install | `<Steam>\steamapps\common\Sid Meier's Civilization VI\Base\Binaries\Win64Steam\` |
| Logs | `%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs\` |
| Mod Files | `%USERPROFILE%\Documents\My Games\Sid Meier's Civilization VI\Mods\ClaudeAI\` |
| DLL Source | `<project-root>\ClaudeMod\` |

**Debug Log Messages:**
- `"[ClaudeIndicator] Tech/Civic completion popups disabled"` - popup suppression working
- `"Action execution complete: X succeeded, Y failed"` - action results
- `"WARNING"` or `"REJECTED"` - validation issues

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Civ6 Game Process                            │
├─────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  version.dll (proxy DLL)                                    │   │
│  │  ├── Forwards calls to real Windows version.dll             │   │
│  │  ├── Hooks GameCore at DllCreateGameContext (+0x752d50)     │   │
│  │  ├── Captures lua_State via pcall hook                      │   │
│  │  ├── Registers SendGameStateToClaudeAPI() in ALL Lua states │   │
│  │  └── Handles Claude API calls (WinHTTP, rate-limited)       │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              ↕ C++ ↔ Lua                            │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  ClaudeAI Mod (Mods/ClaudeAI/)                              │   │
│  │  ├── ClaudeAI.lua - Gameplay context (AddGameplayScripts)   │   │
│  │  │   └── Serializes state, executes actions                 │   │
│  │  └── ClaudeIndicator.lua - UI context (AddUserInterfaces)   │   │
│  │      └── End turn, notifications, government, policies      │   │
│  └─────────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  HavokScript_FinalRelease.dll (Lua VM)                      │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

**Data Flow (Async):**
1. `PlayerTurnStarted` → Serialize game state to JSON
2. `StartClaudeAPIRequest()` returns immediately, spawns background HTTP thread
3. Lua polls `CheckClaudeAPIResponse()` each tick (UI stays responsive)
4. Response ready → Parse JSON → Execute actions sequentially until `end_turn`

**Cross-Context Communication:**
Civ6 has separate Lua environments. Use `Game.SetProperty()`/`GetProperty()` for shared state:
```lua
-- Gameplay sets request
Game.SetProperty("ClaudeAI_RequestEndTurn", 1)
-- UI polls and executes
if Game.GetProperty("ClaudeAI_RequestEndTurn") == 1 then
    UI.RequestAction(ActionTypes.ACTION_ENDTURN)
end
```

---

## Supported Actions

```lua
-- Movement & Combat
{"action": "move_unit", "unit_id": 131073, "x": 10, "y": 15}
{"action": "attack", "unit_id": 131073, "target_x": 11, "target_y": 15}
{"action": "found_city", "unit_id": 131073}

-- Production (units, buildings, districts, wonders, projects)
{"action": "build", "city_id": 65536, "item": "UNIT_SCOUT"}

-- Research & Civics
{"action": "research", "tech": "TECH_POTTERY"}
{"action": "civic", "civic": "CIVIC_CODE_OF_LAWS"}

-- Government & Policies
{"action": "set_government", "government": "GOVERNMENT_CHIEFDOM"}
{"action": "set_policies", "policies": {"0": "POLICY_DISCIPLINE", "1": "POLICY_URBAN_PLANNING"}}

-- Diplomacy
{"action": "denounce", "target_player": 2}
{"action": "declare_war", "target_player": 2, "war_type": "FORMAL"}  -- SURPRISE|FORMAL|HOLY|LIBERATION|RECONQUEST|PROTECTORATE|COLONIAL|TERRITORIAL
{"action": "make_peace", "target_player": 2}
{"action": "dismiss_diplomacy"}

-- Notes (strategy persists across turns, tactical clears each turn)
{"action": "update_notes", "strategy_notes": "Focus science victory", "tactical_notes": "Scout north"}

-- End turn
{"action": "end_turn", "reason": "No more actions"}
```

**Multi-Action Format:**
```json
{"actions": [
    {"action": "build", "city_id": 65536, "item": "UNIT_SCOUT"},
    {"action": "move_unit", "unit_id": 131073, "x": 52, "y": 34},
    {"action": "end_turn"}
]}
```

---

## Game State Structure

Each city includes `canBuild` with dynamically-detected available items:
```lua
canBuild = {
    units = {"UNIT_SCOUT", "UNIT_WARRIOR"},
    buildings = {"BUILDING_MONUMENT"},
    districts = {"DISTRICT_CAMPUS"},
    wonders = {"WONDER_STONEHENGE"},  -- Filtered by global wonder tracking
    projects = {}
}
```

Diplomacy state includes:
- `metPlayers`: Array with `weDenounced`, `theyDenouncedUs`, `turnsUntilFormalWar`, `canDeclareFormally`, `canDeclareWar`
- `atWarWith`, `hasOpenBorders`: Player ID arrays

Passability checking: `IsPlotReachable` validates mountain tunnels (Chemistry tech) and ocean tiles (Cartography tech).

---

## File Structure

**DLL Project (C++):**
```
ClaudeMod/
├── dllmain.cpp              # DLL entry, GameCore hooking
├── HavokScriptIntegration.* # Lua integration, registers API function
├── HavokScript.*            # HavokScript bindings
├── ClaudeAPI.*              # Claude API (WinHTTP), rate limiting
├── Log.*                    # Logging
├── version.def              # DLL exports
└── include/                 # MinHook, nlohmann/json
```

**Lua Mod:**
```
Mods/ClaudeAI/
├── ClaudeAI.modinfo
├── ClaudeAI.lua             # Gameplay: serialization, actions, events
├── system_prompt.txt        # Claude's instructions
└── UI/
    ├── ClaudeIndicator.xml
    └── ClaudeIndicator.lua  # UI: end turn, government, policies
```

---

## Installation

1. **Set API Key:**
   ```cmd
   setx ANTHROPIC_API_KEY "sk-ant-your-key"
   ```

2. **Install DLL:**
   - Backup `version.dll` → `version_original.dll`
   - Copy built `x64/Release/version.dll` to game's `Win64Steam/` folder

3. **Enable Mod:**
   - Launch game → Additional Content → Mods → Enable "Claude AI Player"

4. **Configure (optional):** Edit `ClaudeAI.lua`:
   ```lua
   ClaudeAI.Config = {
       controlledPlayerID = -1,  -- -1 = auto-detect first AI
       enabled = true,
       debugLogging = true,
   }
   ```

---

## Key Technical Details

**Multi-State Registration:** DLL tracks all Lua states via `std::set` and registers `SendGameStateToClaudeAPI` in each (Civ6 has separate UI/Gameplay states).

**Popup Suppression:** Uses `LuaEvents.TutorialUIRoot_DisableTechAndCivicPopups()` to disable tech/civic completion popups when Claude is playing.

**Prerequisite Checking:**
- `HasTechPrereq()`, `HasCivicPrereq()` - Research requirements
- `HasStrategicResource()` - Resource requirements
- `CityHasDistrict()`, `CityHasBuilding()` - District/building requirements
- Population checks for settlers (>1) and districts

**Wonder Tracking:** `ClaudeAI.BuiltWonders` tracks globally-built wonders via `WonderCompleted`, `BuildingAddedToMap`, `BuildingConstructed` events.

---

## Debugging

**Log Files:**
- C++ log: `Win64Steam/civ6_claude_hook.log`
- Lua log: `AppData/Local/Firaxis Games/.../Logs/Lua.log`

**Success Indicators:**
```
Hook for HavokScript::pcall installed successfully
*** LUA STATE CAPTURED via Pcall ***
SendGameStateToClaudeAPI registered successfully
```

**Debug Checklist:**
1. `version.dll` in correct directory?
2. `civ6_claude_hook.log` shows initialization?
3. Log shows "LUA STATE CAPTURED"?
4. Mod enabled in-game?
5. `ANTHROPIC_API_KEY` environment variable set?

---

## Current Status

**Working (Phases 1-7):**
- DLL injection, function hooking, multi-state Lua registration
- Game state serialization with fog of war, dynamic buildables, prerequisites
- Claude API integration with rate limiting, caching, JSON extraction
- Full action execution: movement, combat, production, research, civics, government, policies, diplomacy
- UI indicator, popup suppression, strategy notes system

**TODO (Phase 8):**
- Trade deals, alliances
- Advanced unit commands (fortify, pillage, etc.)
- Great person recruitment
- City-state interactions
- Victory condition pursuit

---

## Credits

Based on [CivilizationVI Community Extension](https://github.com/Wild-W/CivilizationVI_CommunityExtension) by WildW. Uses MinHook, nlohmann/json, WinHTTP.

**Last Updated:** January 2026
