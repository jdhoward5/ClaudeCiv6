#pragma once

// ============================================================================
// ClaudeAPI.h - Claude AI API Integration
// Handles communication with Anthropic's Claude API for game AI decisions
// ============================================================================

#include <string>

#include <json.hpp>

// Convenience alias for nlohmann JSON
using json = nlohmann::json;

namespace ClaudeAPI
{

// ============================================================================
// ASYNC REQUEST STATE
// ============================================================================

/// State of an asynchronous API request
enum class AsyncState
{
    Idle,       ///< No request in progress
    Pending,    ///< Request in progress
    Ready,      ///< Response ready to retrieve
    Failed      ///< Request failed (can't use Error - Windows macro conflict)
};

// ============================================================================
// INITIALIZATION
// ============================================================================

/// Initialize the Claude API (loads API key from environment)
/// @return true if initialization succeeded
[[nodiscard]] bool Initialize();

/// Reset turn tracking (call when starting a new game)
void ResetTurnTracking();

/// Test API connection with a simple query
/// @return true if connection test succeeded
[[nodiscard]] bool TestConnection();

// ============================================================================
// BLOCKING API (Legacy)
// ============================================================================

/// Send game state to Claude and get action back (BLOCKING)
/// @param gameStateJson JSON string containing current game state
/// @return JSON string with action(s) to execute, or error JSON on failure
/// @note This function blocks for several seconds while waiting for response
/// @note Rate limited to one query per turn per player
[[nodiscard]] std::string GetActionFromClaude(const std::string& gameStateJson);

// ============================================================================
// ASYNC API (Non-blocking)
// ============================================================================

/// Start an async request (returns immediately)
/// @param gameStateJson JSON string containing current game state
/// @return true if request was started, false if one is already pending
[[nodiscard]] bool StartAsyncRequest(const std::string& gameStateJson);

/// Check if a response is ready
/// @return Current state of the async request
[[nodiscard]] AsyncState GetAsyncState();

/// Get the async response (only valid when state is Ready)
/// @return Response JSON string, resets state to Idle after retrieval
[[nodiscard]] std::string GetAsyncResponse();

/// Get error message (only valid when state is Failed)
/// @return Error message describing what went wrong
[[nodiscard]] std::string GetAsyncError();

/// Cancel any pending async request
void CancelAsyncRequest();

} // namespace ClaudeAPI
