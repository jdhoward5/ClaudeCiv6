// ============================================================================
// HavokScriptIntegration.cpp - Lua/HavokScript Integration Implementation
// ============================================================================

#include "HavokScriptIntegration.h"

#include <mutex>
#include <set>

#include "ClaudeAPI.h"
#include "Log.h"
#include "MinHook.h"

// ============================================================================
// CONSTANTS
// ============================================================================

namespace
{
    constexpr int kMaxHookRetries = 5;
    constexpr int kRetryDelayMs = 100;
    constexpr size_t kJsonPreviewLength = 512;
    constexpr size_t kLongResponseThreshold = 400;
}

// ============================================================================
// MODULE STATE
// ============================================================================

/// Global Lua state (primary one for DoString)
std::atomic<hks::lua_State*> g_luaState{nullptr};

namespace
{
    /// Original pcall function (before hook)
    hks::hksi_lua_pcallType g_originalPcall = nullptr;

    /// Original dostring function
    hks::DoStringType g_originalDostring = nullptr;

    /// Track if hook is installed
    bool g_pcallHookInstalled = false;

    /// Track which Lua states we've registered our function in
    std::set<hks::lua_State*> g_registeredStates;

    /// Mutex protecting g_registeredStates access from multiple threads
    std::mutex g_registeredStatesMutex;

    /// Track if Claude API has been initialized
    bool g_claudeAPIInitialized = false;
}

// ============================================================================
// FORWARD DECLARATIONS
// ============================================================================

namespace
{
    void RegisterFunctionInState(hks::lua_State* L);
    void PushStringToLua(hks::lua_State* L, const char* str);
    void PushStringToLua(hks::lua_State* L, const std::string& str);
    void LogMinHookError(MH_STATUS status);
    std::string EscapeForLua(const std::string& str);
}

// ============================================================================
// PCALL HOOK
// ============================================================================

namespace
{
    /// Hooked lua_pcall function - captures Lua states and registers functions
    int __cdecl HookedPcall(hks::lua_State* L, int nargs, int nresults, int errfunc)
    {
        // Capture first state for DoString (atomic compare-exchange)
        hks::lua_State* expected = nullptr;
        if (L && g_luaState.compare_exchange_strong(expected, L))
        {
            Log("========================================");
            Log("*** LUA STATE CAPTURED via Pcall ***");
            LogHex("Lua State Address", L);
            Log("========================================");
        }

        // Register our function in EVERY Lua state we encounter
        // This ensures both UI and Gameplay states have access
        if (L && !g_shutdownRequested.load())
        {
            std::lock_guard<std::mutex> lock(g_registeredStatesMutex);
            if (g_registeredStates.find(L) == g_registeredStates.end())
            {
                RegisterFunctionInState(L);
            }
        }

        // Call original
        return g_originalPcall(L, nargs, nresults, errfunc);
    }
}

// ============================================================================
// STRING HELPERS
// ============================================================================

namespace
{
    /// Push a C string to Lua (with fallback methods)
    void PushStringToLua(hks::lua_State* L, const char* str)
    {
        if (hks::pushstring)
        {
            hks::pushstring(L, str);
        }
        else if (hks::pushfstring)
        {
            hks::pushfstring(L, "%s", str);
        }
        else
        {
            Log("[ERROR] No string push function available!");
        }
    }

    /// Push a std::string to Lua with explicit length (safer for long strings)
    void PushStringToLua(hks::lua_State* L, const std::string& str)
    {
        Log("[DEBUG] PushStringToLua called with string length: " + std::to_string(str.length()));
        Log("[DEBUG] pushlstring=" + std::to_string(reinterpret_cast<uintptr_t>(hks::pushlstring)) +
            " pushstring=" + std::to_string(reinterpret_cast<uintptr_t>(hks::pushstring)));

        if (hks::pushlstring)
        {
            Log("[DEBUG] Using pushlstring with length " + std::to_string(str.length()));
            hks::pushlstring(L, str.c_str(), str.length());
        }
        else if (hks::pushstring)
        {
            Log("[DEBUG] Falling back to pushstring (pushlstring not available)");
            hks::pushstring(L, str.c_str());
        }
        else if (hks::pushfstring)
        {
            Log("[DEBUG] Falling back to pushfstring");
            hks::pushfstring(L, "%s", str.c_str());
        }
        else
        {
            Log("[ERROR] No string push function available!");
        }
    }

    /// Escape a string for use in Lua string literal
    std::string EscapeForLua(const std::string& str)
    {
        std::string escaped = str;

        // Escape backslashes first, then quotes
        size_t pos = 0;
        while ((pos = escaped.find('\\', pos)) != std::string::npos)
        {
            escaped.replace(pos, 1, "\\\\");
            pos += 2;
        }

        pos = 0;
        while ((pos = escaped.find('"', pos)) != std::string::npos)
        {
            escaped.replace(pos, 1, "\\\"");
            pos += 2;
        }

        pos = 0;
        while ((pos = escaped.find('\n', pos)) != std::string::npos)
        {
            escaped.replace(pos, 1, "\\n");
            pos += 2;
        }

        pos = 0;
        while ((pos = escaped.find('\r', pos)) != std::string::npos)
        {
            escaped.replace(pos, 1, "\\r");
            pos += 2;
        }

        return escaped;
    }
}

// ============================================================================
// LUA FUNCTION REGISTRATION
// ============================================================================

namespace
{
    /// Register Claude API functions in a specific Lua state
    /// Note: Caller must hold g_registeredStatesMutex lock
    void RegisterFunctionInState(hks::lua_State* L)
    {
        if (!L || g_shutdownRequested.load())
        {
            return;
        }

        // Check if we have the required functions
        if (!hks::pushnamedcclosure || !hks::setfield)
        {
            return; // Can't register without these
        }

        // Initialize Claude API once
        if (!g_claudeAPIInitialized)
        {
            if (ClaudeAPI::Initialize())
            {
                Log("[OK] Claude API initialized successfully");
            }
            else
            {
                Log("[WARNING] Claude API initialization failed");
            }
            g_claudeAPIInitialized = true;
        }

        // Register the BLOCKING function (legacy, still available)
        hks::pushnamedcclosure(L, lua_SendGameStateToClaudeAPI, 0, "SendGameStateToClaudeAPI", 0);
        hks::setfield(L, hks::LUA_GLOBAL, "SendGameStateToClaudeAPI");

        // Register ASYNC functions (new, non-blocking)
        hks::pushnamedcclosure(L, lua_StartClaudeAPIRequest, 0, "StartClaudeAPIRequest", 0);
        hks::setfield(L, hks::LUA_GLOBAL, "StartClaudeAPIRequest");

        hks::pushnamedcclosure(L, lua_CheckClaudeAPIResponse, 0, "CheckClaudeAPIResponse", 0);
        hks::setfield(L, hks::LUA_GLOBAL, "CheckClaudeAPIResponse");

        hks::pushnamedcclosure(L, lua_CancelClaudeAPIRequest, 0, "CancelClaudeAPIRequest", 0);
        hks::setfield(L, hks::LUA_GLOBAL, "CancelClaudeAPIRequest");

        // Track that we've registered in this state
        g_registeredStates.insert(L);

        Log("========================================");
        Log("Registered Claude API functions in Lua state:");
        Log("  - SendGameStateToClaudeAPI (blocking, legacy)");
        Log("  - StartClaudeAPIRequest (async, non-blocking)");
        Log("  - CheckClaudeAPIResponse (async, poll for result)");
        Log("  - CancelClaudeAPIRequest (async, cancel pending)");
        LogHex("State Address", L);
        Log("Total states registered: " + std::to_string(g_registeredStates.size()));
        Log("========================================");
    }
}

// ============================================================================
// INITIALIZATION
// ============================================================================

void InitializeHavokScriptIntegration()
{
    Log("========================================");
    Log("Initializing HavokScript integration...");
    Log("========================================");

    hks::InitHavokScript();

    if (hks::pcall)
    {
        Log("[OK] HavokScript::pcall loaded successfully.");
        LogHex("HavokScript::pcall Address", reinterpret_cast<void*>(hks::pcall));
    }
    else
    {
        Log("[ERROR] Failed to load HavokScript::pcall.");
        return;
    }

    // CRITICAL: We need DoString for ExecuteLuaCode to work
    if (hks::dostring)
    {
        Log("[OK] HavokScript::dostring loaded successfully.");
        LogHex("HavokScript::dostring Address", reinterpret_cast<void*>(hks::dostring));
        // Store it for use in ExecuteLuaCode
        g_originalDostring = hks::dostring;
    }
    else
    {
        Log("[ERROR] Failed to load HavokScript::dostring - ExecuteLuaCode won't work!");
    }

    // Log other important functions
    Log(hks::getfield ? "[OK] getfield loaded" : "[ERROR] getfield NOT loaded");
    Log(hks::setfield ? "[OK] setfield loaded" : "[ERROR] setfield NOT loaded");
    Log(hks::pushinteger ? "[OK] pushinteger loaded" : "[ERROR] pushinteger NOT loaded");
    Log(hks::pushnamedcclosure ? "[OK] pushnamedcclosure loaded" : "[ERROR] pushnamedcclosure NOT loaded");
    Log(hks::gettop ? "[OK] gettop loaded" : "[ERROR] gettop NOT loaded");
    Log(hks::checklstring ? "[OK] checklstring loaded" : "[ERROR] checklstring NOT loaded");

    Log("HavokScript integration initialized");
    Log("========================================");
}

void InstallPcallHook()
{
    if (!hks::pcall)
    {
        Log("[ERROR] Cannot install pcall hook: HavokScript::pcall is null.");
        return;
    }

    Log("Installing hook for HavokScript::pcall...");
    Log("(This will capture lua_State when game calls pcall)");

    for (int attempt = 1; attempt <= kMaxHookRetries; attempt++)
    {
        MH_STATUS status = MH_CreateHook(
            hks::pcall,
            &HookedPcall,
            reinterpret_cast<LPVOID*>(&g_originalPcall));

        if (status == MH_OK)
        {
            status = MH_EnableHook(hks::pcall);
            if (status == MH_OK)
            {
                Log("[OK] Hook for HavokScript::pcall installed successfully.");
                Log("     Waiting for game to call pcall...");
                g_pcallHookInstalled = true;
                return;
            }
            else
            {
                Log("[ERROR] Failed to enable pcall hook (MH_STATUS: " + std::to_string(status) + ")");
                return;
            }
        }
        else if (status == MH_ERROR_ALREADY_CREATED)
        {
            Log("[WARNING] pcall hook already created. Attempting to enable...");
            status = MH_EnableHook(hks::pcall);
            if (status == MH_OK || status == MH_ERROR_ENABLED)
            {
                Log("[OK] pcall hook enabled successfully.");
                g_pcallHookInstalled = true;
                return;
            }
            else
            {
                Log("[ERROR] Failed to enable existing pcall hook (MH_STATUS: " + std::to_string(status) + ")");
                return;
            }
        }
        else if (status == MH_ERROR_MEMORY_ALLOC && attempt < kMaxHookRetries)
        {
            // Memory allocation failed - this can be transient, retry after a short delay
            Log("[WARNING] Memory allocation failed on attempt " + std::to_string(attempt) +
                "/" + std::to_string(kMaxHookRetries) +
                ", retrying in " + std::to_string(kRetryDelayMs) + "ms...");
            Sleep(kRetryDelayMs);
            continue;
        }
        else
        {
            Log("[ERROR] Failed to create pcall hook (MH_STATUS: " + std::to_string(status) + ")");
            LogMinHookError(status);
            return;
        }
    }
}

// ============================================================================
// MINHOOK ERROR LOGGING
// ============================================================================

namespace
{
    /// Log descriptive message for MinHook status codes
    void LogMinHookError(MH_STATUS status)
    {
        switch (status)
        {
        case MH_ERROR_ALREADY_INITIALIZED:
            Log("  -> MinHook already initialized");
            break;
        case MH_ERROR_NOT_INITIALIZED:
            Log("  -> MinHook not initialized");
            break;
        case MH_ERROR_ALREADY_CREATED:
            Log("  -> Hook already created for this target");
            break;
        case MH_ERROR_NOT_CREATED:
            Log("  -> Hook not created");
            break;
        case MH_ERROR_ENABLED:
            Log("  -> Hook already enabled");
            break;
        case MH_ERROR_DISABLED:
            Log("  -> Hook disabled");
            break;
        case MH_ERROR_NOT_EXECUTABLE:
            Log("  -> Target is not executable memory");
            break;
        case MH_ERROR_UNSUPPORTED_FUNCTION:
            Log("  -> Function too small or unsupported");
            break;
        case MH_ERROR_MEMORY_ALLOC:
            Log("  -> Memory allocation failed");
            break;
        case MH_ERROR_MEMORY_PROTECT:
            Log("  -> Memory protection failed");
            break;
        default:
            Log("  -> Unknown error code");
            break;
        }
    }
}

// ============================================================================
// CLEANUP
// ============================================================================

void CleanupHavokScriptIntegration()
{
    Log("CleanupHavokScriptIntegration() called");

    if (g_pcallHookInstalled && hks::pcall)
    {
        Log("Removing HavokScript::pcall hook...");
        MH_DisableHook(hks::pcall);
        MH_RemoveHook(hks::pcall);
        g_pcallHookInstalled = false;
        Log("[OK] HavokScript::pcall hook removed.");
    }

    // Clear all state (use atomic store and mutex)
    g_luaState.store(nullptr);
    g_originalPcall = nullptr;
    g_originalDostring = nullptr;

    {
        std::lock_guard<std::mutex> lock(g_registeredStatesMutex);
        g_registeredStates.clear();
    }

    Log("HavokScript integration cleaned up");
}

// ============================================================================
// LUA CODE EXECUTION
// ============================================================================

bool ExecuteLuaCode(const char* code)
{
    // Don't execute during shutdown
    if (g_shutdownRequested.load())
    {
        Log("[WARNING] Cannot execute Lua code: shutdown in progress.");
        return false;
    }

    hks::lua_State* L = g_luaState.load();
    if (!L)
    {
        Log("[ERROR] Cannot execute Lua code: Lua state is null.");
        return false;
    }

    // CRITICAL: We must use DoString here, NOT pcall
    // pcall expects compiled Lua code on the stack, DoString compiles and executes a string
    if (!g_originalDostring)
    {
        Log("[ERROR] Cannot execute Lua code: DoString not available.");
        return false;
    }

    Log(std::string("[INFO] Executing Lua code: ") + code);

    // DoString compiles and executes the Lua code string
    int result = g_originalDostring(L, code);

    if (result == 0)
    {
        Log("[OK] Lua code executed successfully.");
        return true;
    }
    else
    {
        Log("[ERROR] Lua code execution failed with error code: " + std::to_string(result));
        return false;
    }
}

// ============================================================================
// LUA-CALLABLE FUNCTIONS: BLOCKING API
// ============================================================================

int lua_SendGameStateToClaudeAPI(hks::lua_State* L)
{
    // Don't process during shutdown
    if (g_shutdownRequested.load())
    {
        Log("[WARNING] SendGameStateToClaudeAPI called during shutdown, ignoring");
        PushStringToLua(L, R"({"error":"Shutdown in progress"})");
        return 1;
    }

    Log("========================================");
    Log("lua_SendGameStateToClaudeAPI called from Lua!");
    Log("========================================");

    int numArgs = hks::gettop ? hks::gettop(L) : 0;
    Log("Number of arguments passed from Lua: " + std::to_string(numArgs));

    if (numArgs >= 1 && hks::checklstring)
    {
        size_t len = 0;
        const char* gameStateJson = hks::checklstring(L, 1, &len);

        if (gameStateJson && len > 0)
        {
            Log("Received game state JSON from Lua:");

            // Log preview
            size_t logLen = len > kJsonPreviewLength ? kJsonPreviewLength : len;
            Log(std::string("JSON preview: ") + std::string(gameStateJson, logLen));
            Log(std::string("Total JSON length: ") + std::to_string(len) + " bytes");

            // Call Claude API to get action
            std::string gameStateStr(gameStateJson, len);
            std::string actionJson = ClaudeAPI::GetActionFromClaude(gameStateStr);

            Log("Action received from Claude (length=" + std::to_string(actionJson.length()) + "): " + actionJson);

            // Push the result string back to Lua using pushlstring for full length
            PushStringToLua(L, actionJson);
            Log("Pushed action JSON back to Lua.");
            return 1;
        }
    }

    Log("[ERROR] No valid game state received");
    PushStringToLua(L, R"({"error":"No game state received"})");
    return 1;
}

// ============================================================================
// LUA-CALLABLE FUNCTIONS: ASYNC API
// ============================================================================

int lua_StartClaudeAPIRequest(hks::lua_State* L)
{
    if (g_shutdownRequested.load())
    {
        Log("[WARNING] StartClaudeAPIRequest called during shutdown");
        if (hks::pushboolean != nullptr)
        {
            hks::pushboolean(L, 0);
        }
        else if (hks::pushinteger != nullptr)
        {
            hks::pushinteger(L, 0);
        }
        return 1;
    }

    Log("[ASYNC LUA] StartClaudeAPIRequest called");

    int numArgs = hks::gettop ? hks::gettop(L) : 0;
    if (numArgs >= 1 && hks::checklstring)
    {
        size_t len = 0;
        const char* gameStateJson = hks::checklstring(L, 1, &len);

        if (gameStateJson && len > 0)
        {
            std::string gameStateStr(gameStateJson, len);

            // Log preview
            size_t logLen = len > kJsonPreviewLength ? kJsonPreviewLength : len;
            Log("[ASYNC LUA] Game state preview: " + std::string(gameStateJson, logLen));

            bool started = ClaudeAPI::StartAsyncRequest(gameStateStr);

            Log(std::string("[ASYNC LUA] Request started: ") + (started ? "true" : "false"));

            if (hks::pushboolean != nullptr)
            {
                hks::pushboolean(L, started ? 1 : 0);
            }
            else if (hks::pushinteger != nullptr)
            {
                hks::pushinteger(L, started ? 1 : 0);
            }
            return 1;
        }
    }

    Log("[ASYNC LUA] ERROR: No valid game state received");
    if (hks::pushboolean != nullptr)
    {
        hks::pushboolean(L, 0);
    }
    else if (hks::pushinteger != nullptr)
    {
        hks::pushinteger(L, 0);
    }
    return 1;
}

int lua_CheckClaudeAPIResponse(hks::lua_State* L)
{
    if (g_shutdownRequested.load())
    {
        Log("[WARNING] CheckClaudeAPIResponse called during shutdown");
        PushStringToLua(L, "error");
        PushStringToLua(L, "Shutdown in progress");
        return 2;
    }

    ClaudeAPI::AsyncState state = ClaudeAPI::GetAsyncState();

    switch (state)
    {
    case ClaudeAPI::AsyncState::Idle:
        Log("[ASYNC LUA] CheckClaudeAPIResponse: IDLE (no request)");
        PushStringToLua(L, "idle");
        return 1;

    case ClaudeAPI::AsyncState::Pending:
        // Still waiting - return "pending"
        PushStringToLua(L, "pending");
        return 1;

    case ClaudeAPI::AsyncState::Ready:
    {
        // Response ready - retrieve and return it
        std::string response = ClaudeAPI::GetAsyncResponse();
        Log("[ASYNC LUA] CheckClaudeAPIResponse: READY, response length=" +
            std::to_string(response.length()));

        // WORKAROUND: pushfstring has a 512 byte limit, so we use Game.SetProperty
        // to pass long strings and return just the length
        if (response.length() > kLongResponseThreshold)
        {
            // Store response in Game property via Lua execution
            std::string escaped = EscapeForLua(response);
            std::string luaCode = "Game.SetProperty(\"ClaudeAI_LongResponse\", \"" + escaped + "\")";
            Log("[ASYNC LUA] Storing long response via Game.SetProperty");

            if (hks::dostring)
            {
                int result = hks::dostring(L, luaCode.c_str());
                if (result == 0)
                {
                    Log("[ASYNC LUA] Successfully stored response in Game property");
                    PushStringToLua(L, "ready_long");
                    return 1;
                }
                else
                {
                    Log("[ASYNC LUA] Failed to store response in Game property, error=" +
                        std::to_string(result));
                }
            }
        }

        // For short responses or if Game.SetProperty failed, use direct push
        PushStringToLua(L, "ready");
        PushStringToLua(L, response);
        return 2;
    }

    case ClaudeAPI::AsyncState::Failed:
    {
        // Error occurred
        std::string errorMsg = ClaudeAPI::GetAsyncError();
        Log("[ASYNC LUA] CheckClaudeAPIResponse: ERROR - " + errorMsg);
        PushStringToLua(L, "error");
        PushStringToLua(L, errorMsg.c_str());
        return 2;
    }

    default:
        Log("[ASYNC LUA] CheckClaudeAPIResponse: Unknown state");
        PushStringToLua(L, "error");
        PushStringToLua(L, "Unknown state");
        return 2;
    }
}

int lua_CancelClaudeAPIRequest(hks::lua_State* L)
{
    Log("[ASYNC LUA] CancelClaudeAPIRequest called");
    ClaudeAPI::CancelAsyncRequest();
    return 0;
}
