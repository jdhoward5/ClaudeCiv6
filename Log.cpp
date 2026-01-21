// ============================================================================
// Log.cpp - Unified Logging System Implementation
// ============================================================================

#include "Log.h"

#include <cstdio>
#include <fstream>
#include <Windows.h>

// ============================================================================
// CONSTANTS
// ============================================================================

namespace
{
    constexpr const char* kLogFileName = "civ6_claude_hook.log";
    constexpr size_t kTimestampBufferSize = 64;
    constexpr size_t kHexBufferSize = 128;
}

// ============================================================================
// IMPLEMENTATION
// ============================================================================

std::string GetTimestamp()
{
    SYSTEMTIME st;
    GetLocalTime(&st);

    char buffer[kTimestampBufferSize];
    sprintf_s(buffer, "[%02d:%02d:%02d.%03d]",
        st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);

    return std::string(buffer);
}

void Log(const std::string& message)
{
    std::string timestamped = GetTimestamp() + " " + message;

    // Output to debug console (visible in DebugView)
    OutputDebugStringA((timestamped + "\n").c_str());

    // Also write to file
    std::ofstream logFile(kLogFileName, std::ios::app);
    if (logFile.is_open())
    {
        logFile << timestamped << std::endl;
        logFile.flush();
    }
}

void LogHex(const std::string& name, void* address)
{
    char buffer[kHexBufferSize];
    sprintf_s(buffer, "%s: 0x%p", name.c_str(), address);
    Log(buffer);
}

void InitLog()
{
    std::ofstream logFile(kLogFileName, std::ios::out | std::ios::trunc);
    if (logFile.is_open())
    {
        logFile << "=== Civ6 Claude Hook Initialized ===" << std::endl;
        logFile << "Timestamp: " << GetTimestamp() << std::endl;
        logFile << "========================================" << std::endl;
    }
}
