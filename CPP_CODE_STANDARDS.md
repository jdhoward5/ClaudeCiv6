# C++ Code Standards for Claude AI Mod

**Purpose:** Establish consistent coding practices for C++ code in the Civ6 Claude AI mod.
**Target:** Microsoft Visual C++, Windows SDK, x64 Release builds.
**Last Updated:** January 18, 2026

---

## Table of Contents

1. [File Organization](#1-file-organization)
2. [Naming Conventions](#2-naming-conventions)
3. [Constants and Magic Values](#3-constants-and-magic-values)
4. [Bracing and Indentation](#4-bracing-and-indentation)
5. [Memory and Resource Management](#5-memory-and-resource-management)
6. [Error Handling](#6-error-handling)
7. [Functions](#7-functions)
8. [Classes and Structs](#8-classes-and-structs)
9. [Threading and Synchronization](#9-threading-and-synchronization)
10. [Windows API Patterns](#10-windows-api-patterns)

---

## 1. File Organization

### Header Files (.h)

```cpp
#pragma once

// System headers first (alphabetically)
#include <string>
#include <vector>
#include <Windows.h>

// Project headers second (alphabetically)
#include "Log.h"
#include "HavokScript.h"

// Forward declarations
namespace MyNamespace {
    class MyClass;
}

// Constants
namespace MyNamespace {
    constexpr int kMaxRetries = 5;
    constexpr int kDefaultTimeout = 1000;
}

// Type definitions
namespace MyNamespace {
    using CallbackFn = void(*)(int, void*);
}

// Class/function declarations
namespace MyNamespace {
    bool Initialize();
    void Cleanup();
}
```

### Source Files (.cpp)

```cpp
// Corresponding header first
#include "MyFile.h"

// System headers
#include <algorithm>
#include <mutex>

// Project headers
#include "Log.h"

// Link libraries (for Windows)
#pragma comment(lib, "winhttp.lib")

// Anonymous namespace for file-local items
namespace {
    constexpr int kInternalBufferSize = 256;

    bool IsValidInput(const std::string& input) {
        return !input.empty();
    }
}

// Implementation
namespace MyNamespace {
    // ... implementation
}
```

### Section Headers

Use consistent section dividers:

```cpp
// ============================================================================
// SECTION NAME
// Brief description of what this section contains
// ============================================================================
```

---

## 2. Naming Conventions

### Variables

| Type | Convention | Example |
|------|------------|---------|
| Local variables | camelCase | `playerCount`, `isEnabled` |
| Global variables | `g_` prefix + camelCase | `g_luaState`, `g_asyncMutex` |
| Static file-local | `s_` prefix + camelCase | `s_cachedResponse` |
| Member variables | `m_` prefix + camelCase | `m_isInitialized` |
| Constants | `k` prefix + PascalCase | `kMaxRetries`, `kDefaultTimeout` |
| Macro constants | UPPER_SNAKE_CASE | `MAX_PATH`, `LUA_GLOBAL` |
| Boolean variables | Prefix with `is`, `has`, `can`, `should` | `isReady`, `hasError` |
| Pointers | `p` prefix for raw pointers to external APIs | `pPlayer`, `pCallback` |

### Functions

| Type | Convention | Example |
|------|------------|---------|
| Free functions | PascalCase | `InitializeHooks()`, `GetTimestamp()` |
| Member functions | PascalCase | `ProcessRequest()`, `GetState()` |
| Getters | `Get` prefix | `GetPlayerID()`, `GetAsyncState()` |
| Setters | `Set` prefix | `SetEnabled()`, `SetTimeout()` |
| Boolean queries | `Is`, `Has`, `Can`, `Should` | `IsReady()`, `HasPendingRequest()` |
| Private helpers | PascalCase (same as public) | `ValidateInput()`, `CleanupResources()` |

### Types

| Type | Convention | Example |
|------|------------|---------|
| Classes | PascalCase | `AsyncRequestHandler` |
| Structs | PascalCase | `VersionFunctions` |
| Enums | PascalCase | `AsyncState` |
| Enum values | PascalCase | `Idle`, `Pending`, `Ready` |
| Type aliases | PascalCase with `_t` for function pointers | `GetVersionInfo_t` |
| Namespaces | PascalCase | `ClaudeAPI`, `HavokScript` |

### File Names

| Type | Convention | Example |
|------|------------|---------|
| Header files | PascalCase.h | `ClaudeAPI.h`, `HavokScriptIntegration.h` |
| Source files | PascalCase.cpp | `ClaudeAPI.cpp`, `dllmain.cpp` (exception) |

---

## 3. Constants and Magic Values

### Use Named Constants

```cpp
// Bad - magic numbers
if (statusCode != 200) { ... }
Sleep(500);
char buffer[128];

// Good - named constants
namespace {
    constexpr DWORD kHttpStatusOK = 200;
    constexpr DWORD kPollIntervalMs = 500;
    constexpr size_t kLogBufferSize = 128;
}

if (statusCode != kHttpStatusOK) { ... }
Sleep(kPollIntervalMs);
char buffer[kLogBufferSize];
```

### Group Related Constants

```cpp
namespace Config {
    constexpr int kMaxRetries = 5;
    constexpr int kRetryDelayMs = 100;
    constexpr int kTimeoutSeconds = 60;
    constexpr size_t kMaxJsonPreviewLength = 512;
}

namespace Offsets {
    constexpr uintptr_t kDllCreateGameContext = 0x752d50;
    constexpr uintptr_t kLuaStackTop = 0x48;
}
```

### Use `constexpr` Over `#define`

```cpp
// Avoid
#define MAX_BUFFER_SIZE 1024
#define API_VERSION "2023-06-01"

// Prefer
constexpr size_t kMaxBufferSize = 1024;
constexpr const char* kApiVersion = "2023-06-01";
```

---

## 4. Bracing and Indentation

### Use Allman Style Bracing

```cpp
// Function definitions
bool InitializeHooks()
{
    if (g_hooksInstalled)
    {
        return false;
    }

    // Implementation
    return true;
}

// Short single-line conditions can omit braces
if (!ptr) return false;
if (count == 0) return;

// But prefer braces for clarity
if (!ptr)
{
    return false;
}
```

### Indentation

- Use **4 spaces** for indentation (no tabs)
- Namespace contents are not indented
- Switch case labels align with switch

```cpp
namespace ClaudeAPI
{

void ProcessRequest()
{
    switch (state)
    {
    case AsyncState::Idle:
        StartRequest();
        break;

    case AsyncState::Pending:
        WaitForResponse();
        break;

    default:
        HandleError();
        break;
    }
}

} // namespace ClaudeAPI
```

### Line Length

- Maximum 120 characters per line
- Break long function calls at parameters

```cpp
// Long function call
MH_STATUS status = MH_CreateHook(
    targetFunction,
    &HookedCreateGameContext,
    reinterpret_cast<LPVOID*>(&g_originalCreateGameContext));

// Long condition
if (responseJson.contains("content") &&
    responseJson["content"].is_array() &&
    !responseJson["content"].empty())
{
    // ...
}
```

---

## 5. Memory and Resource Management

### RAII for Resources

```cpp
// Bad - manual cleanup required
HANDLE hFile = CreateFile(...);
// ... use hFile ...
CloseHandle(hFile);  // Easy to forget

// Good - RAII wrapper
class ScopedHandle
{
public:
    explicit ScopedHandle(HANDLE h) : m_handle(h) {}
    ~ScopedHandle() { if (m_handle && m_handle != INVALID_HANDLE_VALUE) CloseHandle(m_handle); }

    HANDLE Get() const { return m_handle; }
    explicit operator bool() const { return m_handle && m_handle != INVALID_HANDLE_VALUE; }

    // Non-copyable
    ScopedHandle(const ScopedHandle&) = delete;
    ScopedHandle& operator=(const ScopedHandle&) = delete;

private:
    HANDLE m_handle;
};
```

### Smart Pointers for Dynamic Memory

```cpp
// Use unique_ptr for single ownership
auto buffer = std::make_unique<char[]>(bufferSize);

// Use shared_ptr for shared ownership
auto config = std::make_shared<Configuration>();

// Raw pointers only for non-owning references
void ProcessData(const char* data);  // Non-owning view
```

### Initialize All Variables

```cpp
// Bad
int count;
void* ptr;
bool isReady;

// Good
int count = 0;
void* ptr = nullptr;
bool isReady = false;

// Best - use default member initializers in structs/classes
struct State
{
    int count = 0;
    void* ptr = nullptr;
    bool isReady = false;
};
```

---

## 6. Error Handling

### Return Values for Expected Failures

```cpp
// Use bool for simple success/failure
bool Initialize();

// Use optional for operations that may not have a result
std::optional<std::string> TryReadFile(const std::string& path);

// Use expected/result types for detailed errors (C++23 or custom)
enum class ErrorCode { Success, NotFound, AccessDenied, Unknown };
std::pair<bool, ErrorCode> OpenFile(const std::string& path);
```

### Early Return on Error

```cpp
bool ProcessRequest(const std::string& input)
{
    // Validate early
    if (input.empty())
    {
        Log("ERROR: Empty input");
        return false;
    }

    if (!g_isInitialized)
    {
        Log("ERROR: Not initialized");
        return false;
    }

    // Main logic at normal indent level
    // ...

    return true;
}
```

### Log All Errors

```cpp
if (!WinHttpConnect(...))
{
    DWORD error = GetLastError();
    Log("WinHttpConnect failed: " + std::to_string(error));
    return false;
}
```

### Use try/catch Sparingly

```cpp
// Only for truly exceptional conditions or external library exceptions
try
{
    json parsed = json::parse(response);
    // ...
}
catch (const json::exception& e)
{
    Log("JSON parse error: " + std::string(e.what()));
    return defaultValue;
}
```

---

## 7. Functions

### Keep Functions Small and Focused

- Each function should do one thing
- Aim for 50 lines or fewer per function
- Extract helpers for complex logic

### Parameter Ordering

```cpp
// Input parameters first, output parameters last
bool ReadData(const std::string& path, std::vector<char>& outData);

// Use const reference for input objects
void ProcessJson(const json& input);

// Use pointer for optional parameters
void Configure(const Options* options = nullptr);
```

### Use `[[nodiscard]]` for Important Return Values

```cpp
[[nodiscard]] bool Initialize();
[[nodiscard]] MH_STATUS CreateHook(...);
[[nodiscard]] std::string GetResponse();
```

### Document Complex Functions

```cpp
/// Sends a game state to Claude API and returns the action response.
///
/// @param gameStateJson JSON string containing current game state
/// @return JSON string with action(s) to execute, or error JSON on failure
/// @note This function is blocking and may take several seconds
/// @note Rate limited to one call per turn per player
std::string GetActionFromClaude(const std::string& gameStateJson);
```

---

## 8. Classes and Structs

### Struct for Data, Class for Behavior

```cpp
// Use struct for plain data
struct VersionFunctions
{
    HMODULE hModule = nullptr;
    GetFileVersionInfo_t GetFileVersionInfoA = nullptr;
    GetFileVersionInfo_t GetFileVersionInfoW = nullptr;
};

// Use class for encapsulated behavior
class AsyncRequestHandler
{
public:
    bool StartRequest(const std::string& data);
    AsyncState GetState() const;
    std::string GetResponse();

private:
    std::mutex m_mutex;
    std::atomic<AsyncState> m_state{AsyncState::Idle};
    std::string m_response;
};
```

### Member Order in Classes

```cpp
class MyClass
{
public:
    // Types and aliases
    using Callback = std::function<void(int)>;

    // Static members
    static constexpr int kDefaultValue = 0;

    // Constructors and destructor
    MyClass();
    ~MyClass();

    // Public methods (alphabetically or by functionality)
    void DoSomething();
    int GetValue() const;

protected:
    // Protected members (rarely used)

private:
    // Private methods
    void ValidateState();

    // Private data members (grouped logically)
    int m_value = 0;
    bool m_isValid = false;
    std::mutex m_mutex;
};
```

---

## 9. Threading and Synchronization

### Use Standard Library Threading

```cpp
// Prefer std::thread over CreateThread for new code
std::thread worker([this]() { ProcessInBackground(); });

// Always join or detach
if (worker.joinable())
{
    worker.join();
}
```

### Protect Shared State

```cpp
// Use mutex for shared data
std::mutex g_dataMutex;
std::string g_sharedData;

void SetData(const std::string& data)
{
    std::lock_guard<std::mutex> lock(g_dataMutex);
    g_sharedData = data;
}

// Use atomic for simple flags
std::atomic<bool> g_shutdownRequested{false};
std::atomic<AsyncState> g_state{AsyncState::Idle};
```

### Avoid Deadlocks

```cpp
// Always acquire locks in consistent order
// Use std::scoped_lock for multiple locks (C++17)
std::scoped_lock lock(mutex1, mutex2);

// Keep lock scope minimal
{
    std::lock_guard<std::mutex> lock(m_mutex);
    // Only critical section here
}
// Work with copied data outside lock
```

---

## 10. Windows API Patterns

### Handle Cleanup Pattern

```cpp
bool MakeHttpRequest()
{
    HINTERNET hSession = nullptr;
    HINTERNET hConnect = nullptr;
    HINTERNET hRequest = nullptr;

    // Use scope exit or defer pattern
    auto cleanup = [&]()
    {
        if (hRequest) WinHttpCloseHandle(hRequest);
        if (hConnect) WinHttpCloseHandle(hConnect);
        if (hSession) WinHttpCloseHandle(hSession);
    };

    hSession = WinHttpOpen(...);
    if (!hSession)
    {
        cleanup();
        return false;
    }

    // ... rest of function ...

    cleanup();
    return true;
}
```

### String Conversion

```cpp
// UTF-8 to Wide
std::wstring Utf8ToWide(const std::string& str)
{
    if (str.empty()) return std::wstring();

    int sizeNeeded = MultiByteToWideChar(
        CP_UTF8, 0,
        str.c_str(), static_cast<int>(str.size()),
        nullptr, 0);

    std::wstring wideStr(sizeNeeded, 0);
    MultiByteToWideChar(
        CP_UTF8, 0,
        str.c_str(), static_cast<int>(str.size()),
        &wideStr[0], sizeNeeded);

    return wideStr;
}
```

### Critical Section Pattern

```cpp
// Initialize in DLL_PROCESS_ATTACH
CRITICAL_SECTION g_criticalSection;
InitializeCriticalSection(&g_criticalSection);

// Use RAII wrapper
class CriticalSectionLock
{
public:
    explicit CriticalSectionLock(CRITICAL_SECTION& cs) : m_cs(cs)
    {
        EnterCriticalSection(&m_cs);
    }
    ~CriticalSectionLock()
    {
        LeaveCriticalSection(&m_cs);
    }

    CriticalSectionLock(const CriticalSectionLock&) = delete;
    CriticalSectionLock& operator=(const CriticalSectionLock&) = delete;

private:
    CRITICAL_SECTION& m_cs;
};

// Usage
void SafeOperation()
{
    CriticalSectionLock lock(g_criticalSection);
    // ... protected code ...
}
```

---

## Quick Reference Checklist

Before committing code, verify:

- [ ] All magic numbers/strings extracted to named constants
- [ ] Variables initialized at declaration
- [ ] Resources cleaned up properly (RAII or explicit)
- [ ] Error conditions logged with context
- [ ] Functions are small (<50 lines) and focused
- [ ] Shared state protected by mutex/atomic
- [ ] Consistent naming conventions used
- [ ] Allman bracing style used
- [ ] 4-space indentation (no tabs)
- [ ] No lines exceeding 120 characters
- [ ] Public functions documented with comments

---

## Migration Notes

When refactoring existing code:

1. **Preserve functionality** - Don't change behavior while reformatting
2. **One file at a time** - Easier to review and test
3. **Test after each change** - Ensure DLL still works
4. **Constants first** - Extract magic values before other changes
5. **Naming last** - Rename identifiers after structure is clean

---

## Files to Exclude from Style Requirements

The following files are from external sources and should not be modified:

- `include/MinHook.h` - Third-party hooking library
- `include/json.hpp` - nlohmann JSON library
- `HavokScript.h` and `HavokScript.cpp` - From Community Extension (minimize changes)

---

**Last Updated:** January 18, 2026
