// ============================================================================
// dllmain.cpp - DLL Entry Point and Version.dll Proxy
// Handles DLL loading, GameCore hooking, and version.dll forwarding
// ============================================================================

#include <Windows.h>
#include <atomic>

#include "ClaudeAPI.h"
#include "HavokScriptIntegration.h"
#include "Log.h"
#include "MinHook.h"

// ============================================================================
// CONSTANTS
// ============================================================================

namespace
{
    /// Offset to DllCreateGameContext in GameCore_XP2_FinalRelease.dll
    constexpr uintptr_t kDllCreateGameContextOffset = 0x752d50;

    /// Time to wait for game initialization after Lua state captured
    constexpr DWORD kGameInitWaitMs = 2000;

    /// Polling interval for Lua state capture
    constexpr DWORD kLuaStatePollIntervalMs = 500;

    /// Maximum time to wait for Lua state (30 seconds)
    constexpr int kLuaStateMaxWaitIterations = 60;

    /// Delay after GameCore detection before hook installation
    constexpr DWORD kGameCoreDetectionDelayMs = 200;

    /// Brief delay during shutdown for threads to notice
    constexpr DWORD kShutdownDelayMs = 100;

    /// Buffer sizes for string conversion
    constexpr size_t kBaseNameBufferSize = 256;
    constexpr size_t kFullNameBufferSize = 512;
    constexpr size_t kErrorBufferSize = 128;
}

// ============================================================================
// UNDOCUMENTED NTDLL STRUCTURES
// Required for DLL load notification callbacks
// ============================================================================

typedef struct _UNICODE_STRING
{
    USHORT Length;
    USHORT MaximumLength;
    PWSTR  Buffer;
} UNICODE_STRING, *PUNICODE_STRING;

typedef struct _LDR_DLL_LOADED_NOTIFICATION_DATA
{
    ULONG Flags;
    PUNICODE_STRING FullDllName;
    PUNICODE_STRING BaseDllName;
    PVOID DllBase;
    ULONG SizeOfImage;
} LDR_DLL_LOADED_NOTIFICATION_DATA, *PLDR_DLL_LOADED_NOTIFICATION_DATA;

typedef struct _LDR_DLL_UNLOADED_NOTIFICATION_DATA
{
    ULONG Flags;
    PUNICODE_STRING FullDllName;
    PUNICODE_STRING BaseDllName;
    PVOID DllBase;
    ULONG SizeOfImage;
} LDR_DLL_UNLOADED_NOTIFICATION_DATA, *PLDR_DLL_UNLOADED_NOTIFICATION_DATA;

typedef union _LDR_DLL_NOTIFICATION_DATA
{
    LDR_DLL_LOADED_NOTIFICATION_DATA Loaded;
    LDR_DLL_UNLOADED_NOTIFICATION_DATA Unloaded;
} LDR_DLL_NOTIFICATION_DATA, *PLDR_DLL_NOTIFICATION_DATA;

typedef const LDR_DLL_NOTIFICATION_DATA* PCLDR_DLL_NOTIFICATION_DATA;

namespace
{
    constexpr ULONG kLdrDllNotificationReasonLoaded = 1;
    constexpr ULONG kLdrDllNotificationReasonUnloaded = 2;
}

typedef VOID(CALLBACK* PLDR_DLL_NOTIFICATION_FUNCTION)(
    ULONG NotificationReason,
    PCLDR_DLL_NOTIFICATION_DATA NotificationData,
    PVOID Context
);

typedef NTSTATUS(NTAPI* LdrRegisterDllNotification_t)(
    ULONG Flags,
    PLDR_DLL_NOTIFICATION_FUNCTION NotificationFunction,
    PVOID Context,
    PVOID* Cookie
);

typedef NTSTATUS(NTAPI* LdrUnregisterDllNotification_t)(
    PVOID Cookie
);

// ============================================================================
// VERSION.DLL FUNCTION TYPES
// ============================================================================

typedef BOOL(WINAPI* GetFileVersionInfoA_t)(LPCSTR, DWORD, DWORD, LPVOID);
typedef BOOL(WINAPI* GetFileVersionInfoW_t)(LPCWSTR, DWORD, DWORD, LPVOID);
typedef DWORD(WINAPI* GetFileVersionInfoSizeA_t)(LPCSTR, LPDWORD);
typedef DWORD(WINAPI* GetFileVersionInfoSizeW_t)(LPCWSTR, LPDWORD);
typedef BOOL(WINAPI* VerQueryValueA_t)(LPCVOID, LPCSTR, LPVOID*, PUINT);
typedef BOOL(WINAPI* VerQueryValueW_t)(LPCVOID, LPCWSTR, LPVOID*, PUINT);

/// Container for original version.dll function pointers
struct OriginalVersionFunctions
{
    HMODULE hOriginal = nullptr;
    GetFileVersionInfoA_t GetFileVersionInfoA = nullptr;
    GetFileVersionInfoW_t GetFileVersionInfoW = nullptr;
    GetFileVersionInfoSizeA_t GetFileVersionInfoSizeA = nullptr;
    GetFileVersionInfoSizeW_t GetFileVersionInfoSizeW = nullptr;
    VerQueryValueA_t VerQueryValueA = nullptr;
    VerQueryValueW_t VerQueryValueW = nullptr;
};

// ============================================================================
// MODULE STATE
// ============================================================================

namespace
{
    /// Original version.dll functions
    OriginalVersionFunctions g_original;

    /// NTDLL notification functions
    LdrRegisterDllNotification_t g_pLdrRegisterDllNotification = nullptr;
    LdrUnregisterDllNotification_t g_pLdrUnregisterDllNotification = nullptr;

    /// Original GameCore function
    typedef void* (__fastcall* DllCreateGameContext_t)();
    DllCreateGameContext_t g_originalCreateGameContext = nullptr;

    /// Hook state tracking
    bool g_hooksInstalled = false;
    CRITICAL_SECTION g_hookLock;
    void* g_gameCoreHookTarget = nullptr;

    /// DLL notification cookie for cleanup
    PVOID g_dllNotificationCookie = nullptr;
}

/// Shutdown flag - signals threads to exit (used by HavokScriptIntegration)
std::atomic<bool> g_shutdownRequested{false};

// ============================================================================
// VERSION.DLL LOADING
// ============================================================================

namespace
{
    /// Load the real version.dll from System32 and get function pointers
    BOOL LoadOriginalVersionDll()
    {
        wchar_t systemPath[MAX_PATH];
        GetSystemDirectoryW(systemPath, MAX_PATH);
        wcscat_s(systemPath, L"\\version.dll");

        g_original.hOriginal = LoadLibraryW(systemPath);
        if (!g_original.hOriginal)
        {
            Log("ERROR: Failed to load original version.dll");
            return FALSE;
        }

        Log("Original version.dll loaded successfully");

#define LOAD_FUNC(name) \
        g_original.name = (name##_t)GetProcAddress(g_original.hOriginal, #name); \
        if (!g_original.name) { Log("ERROR: Failed to load " #name); return FALSE; }

        LOAD_FUNC(GetFileVersionInfoA);
        LOAD_FUNC(GetFileVersionInfoW);
        LOAD_FUNC(GetFileVersionInfoSizeA);
        LOAD_FUNC(GetFileVersionInfoSizeW);
        LOAD_FUNC(VerQueryValueA);
        LOAD_FUNC(VerQueryValueW);

#undef LOAD_FUNC

        Log("All original version.dll functions loaded");
        return TRUE;
    }
}

// ============================================================================
// VERSION.DLL EXPORT FORWARDING
// ============================================================================

extern "C"
{
    BOOL WINAPI GetFileVersionInfoA(LPCSTR lptstrFilename, DWORD dwHandle, DWORD dwLen, LPVOID lpData)
    {
        if (!g_original.GetFileVersionInfoA)
        {
            return FALSE;
        }
        return g_original.GetFileVersionInfoA(lptstrFilename, dwHandle, dwLen, lpData);
    }

    BOOL WINAPI GetFileVersionInfoW(LPCWSTR lptstrFilename, DWORD dwHandle, DWORD dwLen, LPVOID lpData)
    {
        if (!g_original.GetFileVersionInfoW)
        {
            return FALSE;
        }
        return g_original.GetFileVersionInfoW(lptstrFilename, dwHandle, dwLen, lpData);
    }

    DWORD WINAPI GetFileVersionInfoSizeA(LPCSTR lptstrFilename, LPDWORD lpdwHandle)
    {
        if (!g_original.GetFileVersionInfoSizeA)
        {
            return 0;
        }
        return g_original.GetFileVersionInfoSizeA(lptstrFilename, lpdwHandle);
    }

    DWORD WINAPI GetFileVersionInfoSizeW(LPCWSTR lptstrFilename, LPDWORD lpdwHandle)
    {
        if (!g_original.GetFileVersionInfoSizeW)
        {
            return 0;
        }
        return g_original.GetFileVersionInfoSizeW(lptstrFilename, lpdwHandle);
    }

    BOOL WINAPI VerQueryValueA(LPCVOID pBlock, LPCSTR lpSubBlock, LPVOID* lplpBuffer, PUINT puLen)
    {
        if (!g_original.VerQueryValueA)
        {
            return FALSE;
        }
        return g_original.VerQueryValueA(pBlock, lpSubBlock, lplpBuffer, puLen);
    }

    BOOL WINAPI VerQueryValueW(LPCVOID pBlock, LPCWSTR lpSubBlock, LPVOID* lplpBuffer, PUINT puLen)
    {
        if (!g_original.VerQueryValueW)
        {
            return FALSE;
        }
        return g_original.VerQueryValueW(pBlock, lpSubBlock, lplpBuffer, puLen);
    }

    BOOL WINAPI GetFileVersionInfoExA(DWORD dwFlags, LPCSTR lpwstrFilename, DWORD dwHandle, DWORD dwLen, LPVOID lpData)
    {
        return GetFileVersionInfoA(lpwstrFilename, dwHandle, dwLen, lpData);
    }

    BOOL WINAPI GetFileVersionInfoExW(DWORD dwFlags, LPCWSTR lpwstrFilename, DWORD dwHandle, DWORD dwLen, LPVOID lpData)
    {
        return GetFileVersionInfoW(lpwstrFilename, dwHandle, dwLen, lpData);
    }

    DWORD WINAPI GetFileVersionInfoSizeExA(DWORD dwFlags, LPCSTR lpwstrFilename, LPDWORD lpdwHandle)
    {
        return GetFileVersionInfoSizeA(lpwstrFilename, lpdwHandle);
    }

    DWORD WINAPI GetFileVersionInfoSizeExW(DWORD dwFlags, LPCWSTR lpwstrFilename, LPDWORD lpdwHandle)
    {
        return GetFileVersionInfoSizeW(lpwstrFilename, lpdwHandle);
    }
}

// ============================================================================
// GAMECORE HOOKS
// ============================================================================

namespace
{
    /// Thread procedure to wait for Lua state and initialize integration
    DWORD WINAPI LuaStateWaitThread(LPVOID)
    {
        Log("Waiting for Lua state to be captured...");

        for (int i = 0; i < kLuaStateMaxWaitIterations; i++)
        {
            if (g_shutdownRequested.load())
            {
                Log("Lua state thread: shutdown requested, exiting");
                return 0;
            }

            if (g_luaState.load())
            {
                Log("========================================");
                Log("[OK] LUA STATE READY!");
                Log("========================================");

                // Wait a bit more for game to fully initialize
                Sleep(kGameInitWaitMs);

                if (g_shutdownRequested.load())
                {
                    return 0;
                }

                // Test Lua execution (intentionally ignore return values for test prints)
                (void)ExecuteLuaCode("print('========================================')");
                (void)ExecuteLuaCode("print('CLAUDE AI INTEGRATION ACTIVE')");
                (void)ExecuteLuaCode("print('========================================')");

                // Note: Claude API functions are automatically registered in all Lua states
                // via the HookedPcall function in HavokScriptIntegration.cpp

                Log("Claude AI integration complete!");
                return 0;
            }

            Sleep(kLuaStatePollIntervalMs);
        }

        Log("ERROR: Lua state was never captured (timeout)");
        return 1;
    }

    /// Hooked DllCreateGameContext - initializes HavokScript integration
    void* __fastcall HookedCreateGameContext()
    {
        Log("======================================");
        Log("DllCreateGameContext() CALLED!");
        Log("======================================");

        void* result = g_originalCreateGameContext();
        LogHex("Returned GameContext pointer", result);

        // Initialize HavokScript (using Community Extension's code)
        InitializeHavokScriptIntegration();

        // Hook pcall to capture Lua state
        InstallPcallHook();

        // Create thread to wait for Lua state and test
        HANDLE hThread = CreateThread(nullptr, 0, LuaStateWaitThread, nullptr, 0, nullptr);
        if (hThread) CloseHandle(hThread);  // Close handle - thread continues running

        Log("DllCreateGameContext() completed");
        Log("======================================");

        return result;
    }

    /// Install hooks into GameCore DLL
    void InstallGameCoreHooks()
    {
        EnterCriticalSection(&g_hookLock);

        if (g_hooksInstalled)
        {
            Log("Hooks already installed, skipping");
            LeaveCriticalSection(&g_hookLock);
            return;
        }

        Log("InstallGameCoreHooks() called");
        Log("Attempting to locate GameCore_XP2_FinalRelease.dll...");

        HMODULE gameCore = GetModuleHandleA("GameCore_XP2_FinalRelease.dll");
        if (!gameCore)
        {
            Log("GameCore_XP2_FinalRelease.dll not loaded yet");
            LeaveCriticalSection(&g_hookLock);
            return;
        }

        Log("GameCore module found!");
        LogHex("GameCore base address", gameCore);

        void* targetFunction = reinterpret_cast<void*>(
            reinterpret_cast<uintptr_t>(gameCore) + kDllCreateGameContextOffset);
        LogHex("DllCreateGameContext calculated address", targetFunction);

        // Store target for cleanup
        g_gameCoreHookTarget = targetFunction;

        MH_STATUS status = MH_CreateHook(
            targetFunction,
            &HookedCreateGameContext,
            reinterpret_cast<LPVOID*>(&g_originalCreateGameContext));

        if (status != MH_OK)
        {
            char buf[kErrorBufferSize];
            sprintf_s(buf, "ERROR: Failed to create hook! MH_STATUS: %d", status);
            Log(buf);
            LeaveCriticalSection(&g_hookLock);
            return;
        }
        Log("Hook created successfully");

        status = MH_EnableHook(targetFunction);
        if (status != MH_OK)
        {
            char buf[kErrorBufferSize];
            sprintf_s(buf, "ERROR: Failed to enable hook! MH_STATUS: %d", status);
            Log(buf);
            LeaveCriticalSection(&g_hookLock);
            return;
        }

        Log("Hook enabled successfully!");
        Log("Waiting for game to call DllCreateGameContext...");

        g_hooksInstalled = true;
        LeaveCriticalSection(&g_hookLock);
        Log("InstallGameCoreHooks() completed successfully");
    }
}

// ============================================================================
// DLL LOAD NOTIFICATION
// ============================================================================

namespace
{
    /// Callback for DLL load events - watches for GameCore
    VOID CALLBACK DllNotificationCallback(
        ULONG NotificationReason,
        PCLDR_DLL_NOTIFICATION_DATA NotificationData,
        PVOID Context)
    {
        if (NotificationReason == kLdrDllNotificationReasonLoaded)
        {
            const wchar_t* baseDllName = NotificationData->Loaded.BaseDllName->Buffer;
            const wchar_t* fullDllName = NotificationData->Loaded.FullDllName->Buffer;

            char baseBuffer[kBaseNameBufferSize] = { 0 };
            char fullBuffer[kFullNameBufferSize] = { 0 };

            if (baseDllName)
            {
                WideCharToMultiByte(CP_UTF8, 0, baseDllName, -1,
                    baseBuffer, sizeof(baseBuffer) - 1, nullptr, nullptr);
            }
            if (fullDllName)
            {
                WideCharToMultiByte(CP_UTF8, 0, fullDllName, -1,
                    fullBuffer, sizeof(fullBuffer) - 1, nullptr, nullptr);
            }

            Log(std::string("DLL Loaded: ") + baseBuffer);

            if (baseDllName && wcsstr(baseDllName, L"GameCore") != nullptr)
            {
                Log("========================================");
                Log("*** GAMECORE DETECTED IN CALLBACK! ***");
                Log(std::string("  Base name: ") + baseBuffer);
                Log(std::string("  Full path: ") + fullBuffer);
                Log("========================================");

                if (wcsstr(baseDllName, L"XP2") != nullptr && !g_hooksInstalled)
                {
                    Log("This is XP2 GameCore - installing hooks...");
                    Sleep(kGameCoreDetectionDelayMs);
                    InstallGameCoreHooks();
                    Log("Hook installation complete");
                }
                else if (wcsstr(baseDllName, L"Base") != nullptr)
                {
                    Log("Ignoring Base GameCore (we don't have correct offset yet)");
                }
            }
        }
    }

    /// Polling thread to detect GameCore as a backup mechanism
    DWORD WINAPI GameCorePollingThread(LPVOID)
    {
        Log("Polling thread started as backup");

        while (!g_shutdownRequested.load())
        {
            if (g_hooksInstalled)
            {
                Log("Hooks detected as installed, polling thread exiting");
                return 0;
            }

            HMODULE gc = GetModuleHandleA("GameCore_XP2_FinalRelease.dll");
            if (gc)
            {
                Log("*** GAMECORE XP2 DETECTED BY POLLING THREAD! ***");
                LogHex("GameCore_XP2_FinalRelease base address", gc);
                InstallGameCoreHooks();
                return 0;
            }

            Sleep(kLuaStatePollIntervalMs);
        }

        Log("Polling thread: shutdown requested, exiting");
        return 0;
    }
}

// ============================================================================
// DLL ENTRY POINT
// ============================================================================

BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved)
{
    if (ul_reason_for_call == DLL_PROCESS_ATTACH)
    {
        DisableThreadLibraryCalls(hModule);
        InitializeCriticalSection(&g_hookLock);

        InitLog();
        Log("========================================");
        Log("Proxy version.dll loaded into process");
        LogHex("Process base", GetModuleHandle(NULL));
        Log("========================================");

        if (!LoadOriginalVersionDll())
        {
            Log("FATAL: Failed to load original version.dll");
            return FALSE;
        }

        MH_STATUS status = MH_Initialize();
        if (status != MH_OK)
        {
            Log("ERROR: MinHook initialization failed!");
            return FALSE;
        }
        Log("MinHook initialized successfully");

        // Set up DLL load notification
        HMODULE hNtdll = GetModuleHandleA("ntdll.dll");
        if (hNtdll)
        {
            g_pLdrRegisterDllNotification = reinterpret_cast<LdrRegisterDllNotification_t>(
                GetProcAddress(hNtdll, "LdrRegisterDllNotification"));
            g_pLdrUnregisterDllNotification = reinterpret_cast<LdrUnregisterDllNotification_t>(
                GetProcAddress(hNtdll, "LdrUnregisterDllNotification"));

            if (g_pLdrRegisterDllNotification && g_pLdrUnregisterDllNotification)
            {
                Log("ntdll.dll functions loaded successfully");

                NTSTATUS ntStatus = g_pLdrRegisterDllNotification(
                    0,
                    DllNotificationCallback,
                    nullptr,
                    &g_dllNotificationCookie);

                if (ntStatus == 0)
                {
                    Log("DLL load notification registered successfully");
                }
                else
                {
                    Log("WARNING: Failed to register DLL notification");
                }
            }
            else
            {
                Log("WARNING: Failed to load ntdll.dll notification functions");
            }
        }

        // Start polling thread as backup
        HANDLE hPollThread = CreateThread(nullptr, 0, GameCorePollingThread, nullptr, 0, nullptr);
        if (hPollThread) CloseHandle(hPollThread);  // Close handle - thread continues running

        Log("Proxy DLL initialization complete");
        Log("Waiting for GameCore to load...");
    }
    else if (ul_reason_for_call == DLL_PROCESS_DETACH)
    {
        Log("Process detaching - cleaning up");

        // Signal all threads to exit
        g_shutdownRequested.store(true);
        Log("Shutdown flag set, waiting for threads to exit...");
        Sleep(kShutdownDelayMs);

        // Cancel any pending async API requests
        ClaudeAPI::CancelAsyncRequest();
        Log("Async API requests cancelled");

        // Clean up HavokScript integration (removes pcall hook)
        CleanupHavokScriptIntegration();

        // Clean up GameCore hook
        if (g_gameCoreHookTarget)
        {
            Log("Removing GameCore hook...");
            MH_DisableHook(g_gameCoreHookTarget);
            MH_RemoveHook(g_gameCoreHookTarget);
            g_gameCoreHookTarget = nullptr;
            g_hooksInstalled = false;
            Log("[OK] GameCore hook removed");
        }

        // Unregister DLL notification
        if (g_dllNotificationCookie && g_pLdrUnregisterDllNotification)
        {
            g_pLdrUnregisterDllNotification(g_dllNotificationCookie);
            g_dllNotificationCookie = nullptr;
            Log("DLL notification unregistered");
        }

        // Uninitialize MinHook (must be after removing all hooks)
        MH_Uninitialize();
        Log("MinHook uninitialized");

        // Delete critical section
        DeleteCriticalSection(&g_hookLock);

        // Free original version.dll
        if (g_original.hOriginal)
        {
            FreeLibrary(g_original.hOriginal);
            g_original.hOriginal = nullptr;
            Log("Original version.dll freed");
        }

        Log("Cleanup complete");
    }

    return TRUE;
}
