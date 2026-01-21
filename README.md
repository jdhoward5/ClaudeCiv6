# Civ6 Claude AI

Play Civilization VI against Claude AI. This mod replaces the built-in AI with Claude, allowing it to make strategic decisions about unit movement, city production, research, diplomacy, and more.

## Demo

Claude controls a civilization and plays full turns - managing cities, moving units, researching technologies, and engaging in diplomacy.

```
[ClaudeAI] AI Turn Started for Player 1
[ClaudeAI] State: 2 units, 1 cities, 3 enemy units, 55 visible tiles
[ClaudeAI] Received response: {"actions":[
    {"action":"build","city_id":65536,"item":"UNIT_SCOUT"},
    {"action":"move_unit","unit_id":131073,"x":52,"y":34},
    {"action":"research","tech":"TECH_POTTERY"},
    {"action":"end_turn"}
]}
[ClaudeAI] Action execution complete: 4 succeeded, 0 failed
```

## Features

- **Full Game Integration**: Claude receives complete game state (units, cities, resources, diplomacy) and executes actions directly in-game
- **Multi-Action Turns**: Claude plans and executes multiple actions per turn
- **Diplomacy**: Declare war (8 casus belli types), denounce, make peace
- **City Management**: Production queues, district placement, wonder construction
- **Research & Civics**: Technology and civic selection with prerequisite awareness
- **Government & Policies**: Government changes and policy card management
- **Strategy Notes**: Persistent notes across turns for long-term planning

## Requirements

- Civilization VI with Gathering Storm (XP2)
- Windows (64-bit)
- Visual Studio 2019+ (for building)
- [Anthropic API key](https://console.anthropic.com/)

## Installation

### 1. Set Your API Key

```cmd
setx ANTHROPIC_API_KEY "sk-ant-api03-your-key-here"
```

Restart your terminal after setting the environment variable.

### 2. Build the DLL

1. Open `ClaudeMod.sln` in Visual Studio
2. Set configuration to **Release** / **x64**
3. Build the solution

### 3. Install the DLL

Navigate to your Civ6 installation:
```
Steam\steamapps\common\Sid Meier's Civilization VI\Base\Binaries\Win64Steam\
```

1. **Backup** the original `version.dll` (rename to `version_original.dll`)
2. **Copy** the built `x64\Release\version.dll` to this folder

### 4. Install the Lua Mod

Copy the contents of the `Mod/` folder to your mods directory:
```
Mod/* -> Documents\My Games\Sid Meier's Civilization VI\Mods\ClaudeAI\
```

### 5. Enable the Mod

1. Launch Civilization VI
2. Go to **Additional Content** → **Mods**
3. Enable **"Claude AI Player"**
4. Start a new game

## Configuration

Edit `ClaudeAI.lua` to customize behavior:

```lua
ClaudeAI.Config = {
    controlledPlayerID = -1,  -- -1 = auto-detect first AI player
    enabled = true,
    debugLogging = true,
}
```

Edit `system_prompt.txt` to modify Claude's instructions without rebuilding the DLL.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  version.dll (Proxy DLL)                                    │
│  ├── Hooks GameCore initialization                          │
│  ├── Captures Lua state via pcall hook                      │
│  ├── Registers SendGameStateToClaudeAPI() in Lua            │
│  └── Handles Claude API calls (WinHTTP)                     │
└─────────────────────────────────────────────────────────────┘
                              ↕
┌─────────────────────────────────────────────────────────────┐
│  ClaudeAI Mod (Lua)                                         │
│  ├── ClaudeAI.lua - Game state serialization, actions       │
│  └── ClaudeIndicator.lua - UI integration                   │
└─────────────────────────────────────────────────────────────┘
```

**Data Flow:**
1. `PlayerTurnStarted` event triggers
2. Lua serializes game state to JSON
3. C++ sends async HTTP request to Claude API
4. Claude returns action array
5. Lua executes actions sequentially

## Supported Actions

| Action | Example |
|--------|---------|
| Move unit | `{"action": "move_unit", "unit_id": 123, "x": 10, "y": 15}` |
| Attack | `{"action": "attack", "unit_id": 123, "target_x": 11, "target_y": 15}` |
| Found city | `{"action": "found_city", "unit_id": 123}` |
| Build | `{"action": "build", "city_id": 456, "item": "UNIT_SCOUT"}` |
| Research | `{"action": "research", "tech": "TECH_POTTERY"}` |
| Civic | `{"action": "civic", "civic": "CIVIC_CODE_OF_LAWS"}` |
| Government | `{"action": "set_government", "government": "GOVERNMENT_CHIEFDOM"}` |
| Policies | `{"action": "set_policies", "policies": {"0": "POLICY_DISCIPLINE"}}` |
| Declare war | `{"action": "declare_war", "target_player": 2, "war_type": "FORMAL"}` |
| Denounce | `{"action": "denounce", "target_player": 2}` |
| Make peace | `{"action": "make_peace", "target_player": 2}` |
| End turn | `{"action": "end_turn"}` |

## Debugging

**Log files:**
- C++ log: `Win64Steam\civ6_claude_hook.log`
- Lua log: `AppData\Local\Firaxis Games\Sid Meier's Civilization VI\Logs\Lua.log`

**Success indicators:**
```
Hook for HavokScript::pcall installed successfully
*** LUA STATE CAPTURED via Pcall ***
SendGameStateToClaudeAPI registered successfully
```

## Uninstallation

1. Restore the original `version.dll` from your backup
2. Delete the `ClaudeAI` mod folder (optional)

## Project Structure

```
ClaudeCiv6/
├── dllmain.cpp              # DLL entry, GameCore hooking
├── HavokScriptIntegration.* # Lua integration
├── HavokScript.*            # HavokScript bindings
├── ClaudeAPI.*              # Claude API client
├── Log.*                    # Logging utilities
├── version.def              # DLL exports
├── include/                 # MinHook, nlohmann/json
└── Mod/                     # Lua mod (copy to Civ6 Mods folder)
    ├── ClaudeAI.modinfo     # Mod manifest
    ├── ClaudeAI.lua         # Main gameplay script
    ├── system_prompt.txt    # Claude's instructions
    └── UI/
        ├── ClaudeIndicator.xml
        └── ClaudeIndicator.lua
```

## Credits

- Based on [CivilizationVI Community Extension](https://github.com/Wild-W/CivilizationVI_CommunityExtension) by WildW
- [MinHook](https://github.com/TsudaKageworthy/minhook) for function hooking
- [nlohmann/json](https://github.com/nlohmann/json) for JSON parsing

## License

AGPL-3.0 License - This project is a derivative of [CivilizationVI Community Extension](https://github.com/Wild-W/CivilizationVI_CommunityExtension) and is distributed under the same license. See [LICENSE](LICENSE) for details.

## Disclaimer

This is an unofficial mod and is not affiliated with Firaxis Games, 2K Games, or Anthropic. Use at your own risk. The mod modifies game files and may not be compatible with future game updates.
