#pragma once

// ============================================================================
// HavokScriptIntegration.h - Lua/HavokScript Integration
// Provides C++ to Lua bridging for the Claude API functions
// ============================================================================

#include <atomic>

#include "HavokScript.h"

// ============================================================================
// EXTERNAL STATE
// ============================================================================

/// Global Lua state (captured when game executes Lua)
/// Note: Access should be synchronized - use atomic load/store
extern std::atomic<hks::lua_State*> g_luaState;

/// Shutdown flag (defined in dllmain.cpp)
extern std::atomic<bool> g_shutdownRequested;

// ============================================================================
// INITIALIZATION
// ============================================================================

/// Initialize HavokScript function loading
/// Must be called after HavokScript DLL is loaded
void InitializeHavokScriptIntegration();

/// Install pcall hook to capture Lua states
/// This hooks lua_pcall to intercept all Lua calls and register our functions
void InstallPcallHook();

// ============================================================================
// LUA EXECUTION
// ============================================================================

/// Execute Lua code string from C++
/// @param code Lua code to execute
/// @return true if execution succeeded
[[nodiscard]] bool ExecuteLuaCode(const char* code);

// ============================================================================
// LUA-CALLABLE FUNCTIONS
// ============================================================================

/// Send game state to Claude API and get action back (BLOCKING)
/// @note This function blocks for several seconds while waiting for response
/// @note Automatically registered in all Lua states via hooked_pcall
int lua_SendGameStateToClaudeAPI(hks::lua_State* L);

/// Start an async Claude API request (non-blocking)
/// @return 1 (boolean on stack: true if request started)
int lua_StartClaudeAPIRequest(hks::lua_State* L);

/// Check if async response is ready
/// @return 1-2 values: status string, optional response/error
int lua_CheckClaudeAPIResponse(hks::lua_State* L);

/// Cancel any pending async request
/// @return 0 (no values)
int lua_CancelClaudeAPIRequest(hks::lua_State* L);

// ============================================================================
// CLEANUP
// ============================================================================

/// Clean up hooks and state on DLL unload
void CleanupHavokScriptIntegration();
