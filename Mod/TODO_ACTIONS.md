# Claude AI - Missing Actions & Serialization TODO

**Created:** January 18, 2026
**Purpose:** Track implementation of missing player actions to achieve full human-like gameplay

---

## Implementation Status Legend
- ⬜ Not started
- 🟡 In progress
- ✅ Complete

---

## PRIORITY 1 - High Impact (Most Common Human Actions)

### 1.1 Builder/Worker Actions
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ✅ | `build_improvement` | Build farm, mine, quarry, lumber mill, etc. | Medium |
| ✅ | `harvest` | Harvest bonus resource for instant yield | Low |
| ✅ | `remove_feature` | Clear woods, jungle, marsh | Low |
| ✅ | `repair` | Repair pillaged improvement/district | Low |
| ⬜ | `plant_woods` | Plant woods (Conservation civic) | Low |

**Serialization needed:**
- ✅ Available improvements per builder tile (based on terrain, tech, resources)
- ✅ Harvestable resources on current tile
- ✅ Removable features on current tile
- ✅ Repairable improvements nearby

**Action format:**
```json
{"action": "build_improvement", "unit_id": 123, "improvement": "IMPROVEMENT_FARM"}
{"action": "harvest", "unit_id": 123}
{"action": "remove_feature", "unit_id": 123}
{"action": "repair", "unit_id": 123}
```

---

### 1.2 Trade Routes
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ✅ | `send_trade_route` | Send trader to destination city | Medium |

**Serialization needed:**
- ✅ Available trade route destinations (domestic + international)
- ⬜ Projected yields per destination
- ⬜ Active trade routes (source, destination, turns remaining)
- ⬜ Number of available trade route slots

**Action format:**
```json
{"action": "send_trade_route", "unit_id": 123, "destination_city_id": 456}
```

---

### 1.3 Unit Upgrades
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ✅ | `upgrade_unit` | Upgrade unit to next tier | Low |

**Serialization needed:**
- ✅ Upgrade path for each unit (target unit type)
- ✅ Upgrade cost (gold + resources)
- ✅ Whether upgrade is currently available

**Action format:**
```json
{"action": "upgrade_unit", "unit_id": 123}
```

---

### 1.4 Gold/Faith Purchases
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ✅ | `purchase` | Buy unit/building with gold or faith | Medium |

**Serialization needed:**
- ✅ Purchasable items per city (gold)
- ✅ Purchasable items per city (faith)
- ✅ Costs for each item

**Action format:**
```json
{"action": "purchase", "city_id": 123, "item": "UNIT_SETTLER", "currency": "gold"}
{"action": "purchase", "city_id": 123, "item": "BUILDING_SHRINE", "currency": "faith"}
```

---

### 1.5 City Ranged Attack
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ✅ | `city_ranged_attack` | City center bombards enemy | Low |

**Serialization needed:**
- ✅ City ranged strength
- ✅ City attack range
- ✅ Valid targets in range
- ✅ Whether city has already attacked this turn

**Action format:**
```json
{"action": "city_ranged_attack", "city_id": 123, "target_x": 10, "target_y": 15}
```

---

### 1.6 Unit Promotions
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ✅ | `promote` | Select promotion for experienced unit | Medium |

**Serialization needed:**
- ✅ Unit experience / level
- ✅ Available promotions (when unit is ready)
- ✅ Current promotions on unit

**Action format:**
```json
{"action": "promote", "unit_id": 123, "promotion": "PROMOTION_BATTLECRY"}
```

---

## PRIORITY 2 - Medium Impact (Important but Less Frequent)

### 2.1 Religious Actions
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ⬜ | `spread_religion` | Missionary spreads religion | Low |
| ⬜ | `theological_combat` | Apostle attacks religious unit | Low |
| ⬜ | `evangelize_belief` | Apostle adds belief | Medium |
| ⬜ | `launch_inquisition` | Apostle enables inquisitors | Low |
| ⬜ | `remove_heresy` | Inquisitor removes foreign religion | Low |
| ⬜ | `found_religion` | Great Prophet founds religion | Medium |
| ⬜ | `choose_pantheon` | Select pantheon belief | Medium |

**Serialization needed:**
- ⬜ Religion state (founded, name, beliefs)
- ⬜ Holy city location
- ⬜ Religious unit charges
- ⬜ Available beliefs for selection
- ⬜ Cities with foreign religion pressure

**Action format:**
```json
{"action": "spread_religion", "unit_id": 123}
{"action": "theological_combat", "unit_id": 123, "target_x": 10, "target_y": 15}
{"action": "found_religion", "unit_id": 123, "religion": "RELIGION_CHRISTIANITY", "beliefs": ["BELIEF_TITHE", "BELIEF_MOSQUES"]}
{"action": "choose_pantheon", "pantheon": "BELIEF_GOD_OF_THE_FORGE"}
```

---

### 2.2 Espionage
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ⬜ | `assign_spy` | Send spy to city | Medium |
| ⬜ | `spy_mission` | Select spy operation | Medium |
| ⬜ | `counterspy` | Set spy to counterspy mode | Low |

**Serialization needed:**
- ⬜ Spy units and locations
- ⬜ Available missions per city
- ⬜ Mission success probabilities
- ⬜ Spy experience/level

**Action format:**
```json
{"action": "assign_spy", "unit_id": 123, "city_id": 456}
{"action": "spy_mission", "unit_id": 123, "mission": "STEAL_TECH"}
```

---

### 2.3 Great People
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ⬜ | `recruit_great_person` | Claim available great person | Medium |
| ⬜ | `patronize_great_person` | Rush with gold/faith | Medium |
| ⬜ | `activate_great_person` | Use great person ability | High |

**Serialization needed:**
- ⬜ Great person points per type
- ⬜ Available great people for recruitment
- ⬜ Patronage costs
- ⬜ Great person abilities

**Action format:**
```json
{"action": "recruit_great_person", "great_person": "GREAT_PERSON_INDIVIDUAL_HYPATIA"}
{"action": "patronize_great_person", "great_person_class": "GREAT_PERSON_CLASS_SCIENTIST", "currency": "faith"}
{"action": "activate_great_person", "unit_id": 123}
```

---

### 2.4 Military Formations
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ⬜ | `form_corps` | Combine two units into corps | Low |
| ⬜ | `form_army` | Combine corps + unit into army | Low |

**Serialization needed:**
- ⬜ Units eligible for combining
- ⬜ Whether Nationalism civic is unlocked

**Action format:**
```json
{"action": "form_corps", "unit_id": 123, "target_unit_id": 456}
```

---

### 2.5 Diplomacy - Trade Deals
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ⬜ | `propose_trade` | Offer trade deal to AI | High |
| ⬜ | `respond_trade` | Accept/reject incoming deal | Medium |
| ⬜ | `request_agreement` | Request open borders, etc. | Medium |
| ⬜ | `declare_friendship` | Declare friendship | Low |
| ⬜ | `form_alliance` | Form alliance (various types) | Medium |

**Serialization needed:**
- ⬜ Available trade items (resources, gold, cities, etc.)
- ⬜ Incoming trade offers
- ⬜ Relationship levels
- ⬜ Alliance availability and types

**Action format:**
```json
{"action": "propose_trade", "target_player": 2, "offer": {"gold": 100}, "demand": {"resource": "RESOURCE_IRON"}}
{"action": "declare_friendship", "target_player": 2}
{"action": "form_alliance", "target_player": 2, "alliance_type": "ALLIANCE_MILITARY"}
```

---

### 2.6 City-States
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ⬜ | `send_envoy` | Send envoy to city-state | Low |
| ⬜ | `levy_military` | Levy city-state's military | Low |

**Serialization needed:**
- ⬜ City-state list with types
- ⬜ Envoys per city-state (ours and others)
- ⬜ Suzerain status
- ⬜ Available envoys
- ⬜ Levy cost

**Action format:**
```json
{"action": "send_envoy", "city_state_player_id": 15}
{"action": "levy_military", "city_state_player_id": 15}
```

---

## PRIORITY 3 - Lower Impact (Specialized/Late-Game)

### 3.1 Air Units
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ⬜ | `rebase` | Move aircraft to new base | Low |
| ⬜ | `air_strike` | Bomb target | Low |
| ⬜ | `paradrop` | Paradrop infantry | Low |

---

### 3.2 Governors (Rise & Fall / Gathering Storm)
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ⬜ | `appoint_governor` | Unlock new governor | Medium |
| ⬜ | `assign_governor` | Assign governor to city | Low |
| ⬜ | `promote_governor` | Promote governor | Low |

**Serialization needed:**
- ⬜ Available governors
- ⬜ Governor titles/promotions
- ⬜ Current governor assignments
- ⬜ Available governor promotions

---

### 3.3 World Congress (Gathering Storm)
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ⬜ | `vote_resolution` | Vote on World Congress resolution | High |
| ⬜ | `propose_emergency` | Propose emergency | High |

**Serialization needed:**
- ⬜ Active resolutions
- ⬜ Voting options
- ⬜ Diplomatic favor

---

### 3.4 Great Works
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ⬜ | `move_great_work` | Move great work between slots | Medium |

**Serialization needed:**
- ⬜ Great works owned
- ⬜ Available slots
- ⬜ Theming bonuses

---

### 3.5 Archaeology & National Parks
| Status | Action | Description | Complexity |
|--------|--------|-------------|------------|
| ⬜ | `excavate` | Archaeologist excavates site | Low |
| ⬜ | `create_park` | Naturalist creates national park | Low |

---

## Implementation Notes

### How to Add a New Action

1. **Add serialization** in `ClaudeAI.GetGameState()` or helper functions
2. **Add action handler** in `ActionHandlers` table in ClaudeAI.lua
3. **Update system_prompt.txt** to document the new action for Claude
4. **Test** with in-game verification

### Key APIs to Research

- `UnitManager.RequestOperation()` - Most unit actions
- `UnitOperationTypes.*` - Available operations
- `CityManager.RequestCommand()` - City commands
- `PlayerOperations.*` - Player-level operations
- `GameInfo.*` - Database lookups

### Testing Checklist

For each new action:
- [ ] Action executes without errors
- [ ] Action has correct effect in game
- [ ] Serialization provides necessary info
- [ ] Claude can successfully use the action
- [ ] Edge cases handled (no moves, missing prereqs, etc.)

---

## Progress Log

### January 18, 2026
- Created TODO list based on code analysis
- Identified 19 existing actions
- Documented ~40 missing actions across 3 priority tiers
- **IMPLEMENTED PRIORITY 1** (All 6 High-Impact Items Complete!):
  1. **Builder actions** (build_improvement, harvest, remove_feature, repair)
     - Added `ClaudeAI.GetBuilderActions()` helper
     - Unit serialization includes availableImprovements, canHarvest, canRemoveFeature, canRepair
  2. **Trade routes** (send_trade_route)
     - Added `ClaudeAI.GetTradeRouteDestinations()` helper
     - Trader units show tradeDestinations array with domestic/international cities
  3. **Unit upgrades** (upgrade_unit)
     - Added `ClaudeAI.GetUnitUpgradeInfo()` helper
     - Military units show canUpgrade, upgradeType, upgradeCost
  4. **Gold/Faith purchases** (purchase)
     - Added `ClaudeAI.GetPurchasableItems()` helper
     - Cities show canPurchaseGold and canPurchaseFaith with item lists and costs
  5. **City ranged attacks** (city_ranged_attack)
     - Added `ClaudeAI.GetCityCombatInfo()` helper
     - Cities show canAttack, rangedStrength, attackTargets array
  6. **Unit promotions** (promote)
     - Added `ClaudeAI.GetUnitPromotionInfo()` helper
     - Military units show canPromote, availablePromotions, experience, level, promotions
  - Updated system_prompt.txt with documentation for all new actions

**Total Actions Now: 31** (was 19, added 12 new actions)

### January 18, 2026 (Session 2)
- **IMPLEMENTED DISTRICT PLACEMENT AND TILE YIELDS:**
  1. **District placement** (place_district)
     - Added `ClaudeAI.CalculateDistrictAdjacency()` helper - calculates adjacency bonus from terrain/districts
     - Added `ClaudeAI.GetDistrictPlacements()` helper - returns valid placements sorted by adjacency
     - Cities show `districtPlacements` with top 5 locations per district type
     - UI handler in ClaudeIndicator.lua for cross-context district placement
  2. **Enhanced tile yields**
     - Visible tiles now include science, culture, and faith yields (not just food/production/gold)
  - Updated system_prompt.txt with district placement documentation

**Total Actions Now: 32** (added place_district)

---

## Quick Reference: Existing Actions

Already implemented in ClaudeAI.lua:
- `move_unit`, `attack`, `found_city`
- `skip`, `fortify`, `sleep`, `delete`, `pillage`
- `build` (production), `place_district` (district with location)
- `research`, `civic`
- `set_government`, `set_policies`
- `declare_war`, `denounce`, `make_peace`, `dismiss_diplomacy`, `diplomacy_respond`
- `update_notes`, `end_turn`
