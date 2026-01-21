#pragma once

// ============================================================================
// Log.h - Unified Logging System
// Provides timestamped logging to both debug console and file
// ============================================================================

#include <string>

// ============================================================================
// PUBLIC API
// ============================================================================

/// Initialize the log file (call once at DLL startup)
void InitLog();

/// Log a message with timestamp to debug console and file
/// @param message The message to log
void Log(const std::string& message);

/// Log a hex address with a descriptive name
/// @param name Description of the address
/// @param address The pointer value to log
void LogHex(const std::string& name, void* address);

// ============================================================================
// INTERNAL HELPERS
// ============================================================================

/// Get current timestamp string in format [HH:MM:SS.mmm]
std::string GetTimestamp();
