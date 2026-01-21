// ============================================================================
// ClaudeAPI.cpp - Claude AI API Integration Implementation
// ============================================================================

#include "ClaudeAPI.h"
#include "Log.h"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <thread>
#include <utility>
#include <vector>

#include <ShlObj.h>
#include <Windows.h>
#include <winhttp.h>

#pragma comment(lib, "winhttp.lib")

namespace ClaudeAPI
{

// ============================================================================
// CONSTANTS
// ============================================================================

namespace
{
    // API Configuration
    constexpr const char* kApiHost = "api.anthropic.com";
    constexpr const char* kApiPath = "/v1/messages";
    constexpr const char* kApiVersion = "2023-06-01";
    constexpr const char* kDefaultModel = "claude-sonnet-4-5-20250929";
    constexpr int kDefaultMaxTokens = 4096;

    // Logging limits
    constexpr size_t kMaxJsonPreviewLength = 512;
    constexpr size_t kMaxTestResponseTokens = 100;

    // HTTP status codes
    constexpr DWORD kHttpStatusOK = 200;
}

// ============================================================================
// MODULE STATE
// ============================================================================

namespace
{
    // API credentials and configuration
    std::string g_apiKey;
    std::string g_model = kDefaultModel;
    int g_maxTokens = kDefaultMaxTokens;

    // Turn-based rate limiting
    int g_lastQueriedTurn = -1;
    int g_lastQueriedPlayer = -1;
    std::string g_cachedResponse;

    // Async request state
    std::mutex g_asyncMutex;
    std::atomic<AsyncState> g_asyncState{AsyncState::Idle};
    std::string g_asyncResponse;
    std::string g_asyncError;
    std::thread g_asyncThread;
    std::atomic<bool> g_asyncCancelled{false};
}

// ============================================================================
// STRING HELPERS
// ============================================================================

namespace
{

/// Escape special characters for JSON string
std::string EscapeJson(const std::string& s)
{
    std::ostringstream o;
    for (char c : s)
    {
        switch (c)
        {
        case '"': o << "\\\""; break;
        case '\\': o << "\\\\"; break;
        case '\b': o << "\\b"; break;
        case '\f': o << "\\f"; break;
        case '\n': o << "\\n"; break;
        case '\r': o << "\\r"; break;
        case '\t': o << "\\t"; break;
        default:
            if ('\x00' <= c && c <= '\x1f')
            {
                o << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
            }
            else
            {
                o << c;
            }
        }
    }
    return o.str();
}

/// Convert UTF-8 string to wide string for Windows API
std::wstring Utf8ToWide(const std::string& str)
{
    if (str.empty())
    {
        return std::wstring();
    }

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

/// Replace all occurrences of a substring
std::string ReplaceAll(std::string str, const std::string& from, const std::string& to)
{
    size_t pos = 0;
    while ((pos = str.find(from, pos)) != std::string::npos)
    {
        str.replace(pos, from.length(), to);
        pos += to.length();
    }
    return str;
}

} // anonymous namespace

// ============================================================================
// JSON EXTRACTION
// ============================================================================

namespace
{

/// Extract JSON from Claude's response (handles markdown code blocks)
std::string ExtractJsonFromResponse(const std::string& content)
{
    std::string trimmed = content;

    // Strategy 1: Look for ```json ... ``` code blocks
    size_t jsonBlockStart = content.find("```json");
    if (jsonBlockStart != std::string::npos)
    {
        size_t jsonStart = content.find('\n', jsonBlockStart);
        if (jsonStart != std::string::npos)
        {
            jsonStart++; // Skip the newline
            size_t jsonEnd = content.find("```", jsonStart);
            if (jsonEnd != std::string::npos)
            {
                trimmed = content.substr(jsonStart, jsonEnd - jsonStart);
                Log("Extracted JSON from ```json block");
            }
        }
    }
    // Strategy 2: Look for ``` ... ``` code blocks (without language)
    else
    {
        size_t blockStart = content.find("```");
        if (blockStart != std::string::npos)
        {
            size_t jsonStart = content.find('\n', blockStart);
            if (jsonStart != std::string::npos)
            {
                jsonStart++; // Skip the newline
                size_t jsonEnd = content.find("```", jsonStart);
                if (jsonEnd != std::string::npos)
                {
                    trimmed = content.substr(jsonStart, jsonEnd - jsonStart);
                    Log("Extracted JSON from ``` block");
                }
            }
        }
    }

    // Strategy 3: Find JSON object by looking for { ... }
    size_t braceStart = trimmed.find('{');
    if (braceStart != std::string::npos)
    {
        int braceCount = 0;
        size_t braceEnd = std::string::npos;

        for (size_t i = braceStart; i < trimmed.length(); i++)
        {
            if (trimmed[i] == '{')
            {
                braceCount++;
            }
            else if (trimmed[i] == '}')
            {
                braceCount--;
                if (braceCount == 0)
                {
                    braceEnd = i;
                    break;
                }
            }
        }

        if (braceEnd != std::string::npos)
        {
            std::string extracted = trimmed.substr(braceStart, braceEnd - braceStart + 1);

            // Validate it's actually JSON
            try
            {
                json test = json::parse(extracted);
                return extracted;
            }
            catch (const json::exception&)
            {
                Log("Found braces but content wasn't valid JSON");
            }
        }
    }

    // Strategy 4: Return trimmed content
    size_t start = trimmed.find_first_not_of(" \t\n\r");
    size_t end = trimmed.find_last_not_of(" \t\n\r");

    if (start != std::string::npos && end != std::string::npos)
    {
        return trimmed.substr(start, end - start + 1);
    }

    return trimmed;
}

} // anonymous namespace

// ============================================================================
// HTTP COMMUNICATION
// ============================================================================

namespace
{

/// Make HTTP POST request to Claude API
std::string HttpPost(const std::string& host, const std::string& path,
                     const std::string& body, const std::string& apiKey)
{
    std::string response;
    HINTERNET hSession = nullptr;
    HINTERNET hConnect = nullptr;
    HINTERNET hRequest = nullptr;

    // Cleanup lambda
    auto cleanup = [&]()
    {
        if (hRequest) WinHttpCloseHandle(hRequest);
        if (hConnect) WinHttpCloseHandle(hConnect);
        if (hSession) WinHttpCloseHandle(hSession);
    };

    // Initialize WinHTTP
    hSession = WinHttpOpen(
        L"Civ6ClaudeAI/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0);

    if (!hSession)
    {
        Log("WinHttpOpen failed: " + std::to_string(GetLastError()));
        cleanup();
        return "";
    }

    // Connect to server
    std::wstring wideHost = Utf8ToWide(host);
    hConnect = WinHttpConnect(hSession, wideHost.c_str(), INTERNET_DEFAULT_HTTPS_PORT, 0);

    if (!hConnect)
    {
        Log("WinHttpConnect failed: " + std::to_string(GetLastError()));
        cleanup();
        return "";
    }

    // Create request
    std::wstring widePath = Utf8ToWide(path);
    hRequest = WinHttpOpenRequest(
        hConnect,
        L"POST",
        widePath.c_str(),
        nullptr,
        WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES,
        WINHTTP_FLAG_SECURE);

    if (!hRequest)
    {
        Log("WinHttpOpenRequest failed: " + std::to_string(GetLastError()));
        cleanup();
        return "";
    }

    // Build headers
    std::wstring headers = L"Content-Type: application/json\r\n";
    headers += L"x-api-key: " + Utf8ToWide(apiKey) + L"\r\n";
    headers += L"anthropic-version: " + Utf8ToWide(kApiVersion) + L"\r\n";

    // Send request
    BOOL bResults = WinHttpSendRequest(
        hRequest,
        headers.c_str(),
        static_cast<DWORD>(-1),
        const_cast<char*>(body.c_str()),
        static_cast<DWORD>(body.size()),
        static_cast<DWORD>(body.size()),
        0);

    if (!bResults)
    {
        Log("WinHttpSendRequest failed: " + std::to_string(GetLastError()));
        cleanup();
        return "";
    }

    // Receive response
    bResults = WinHttpReceiveResponse(hRequest, nullptr);

    if (!bResults)
    {
        Log("WinHttpReceiveResponse failed: " + std::to_string(GetLastError()));
        cleanup();
        return "";
    }

    // Check status code
    DWORD statusCode = 0;
    DWORD statusCodeSize = sizeof(statusCode);
    WinHttpQueryHeaders(
        hRequest,
        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX,
        &statusCode,
        &statusCodeSize,
        WINHTTP_NO_HEADER_INDEX);

    if (statusCode != kHttpStatusOK)
    {
        Log("HTTP request failed with status: " + std::to_string(statusCode));
    }

    // Read response data
    DWORD dwSize = 0;
    DWORD dwDownloaded = 0;

    do
    {
        dwSize = 0;
        if (!WinHttpQueryDataAvailable(hRequest, &dwSize))
        {
            Log("WinHttpQueryDataAvailable failed: " + std::to_string(GetLastError()));
            break;
        }

        if (dwSize == 0) break;

        std::vector<char> chunk(dwSize + 1, 0);
        if (!WinHttpReadData(hRequest, chunk.data(), dwSize, &dwDownloaded))
        {
            Log("WinHttpReadData failed: " + std::to_string(GetLastError()));
            break;
        }

        response.append(chunk.data(), dwDownloaded);
    } while (dwSize > 0);

    cleanup();
    return response;
}

} // anonymous namespace

// ============================================================================
// GAME STATE PARSING
// ============================================================================

namespace
{

/// Extract turn number and player ID from game state JSON
std::pair<int, int> ExtractTurnAndPlayer(const std::string& gameStateJson)
{
    int turn = -1;
    int playerID = -1;

    try
    {
        json gameState = json::parse(gameStateJson);

        if (gameState.contains("turn"))
        {
            turn = gameState["turn"].get<int>();
        }
        if (gameState.contains("playerID"))
        {
            playerID = gameState["playerID"].get<int>();
        }
    }
    catch (const json::exception& e)
    {
        Log("Warning: Could not extract turn/player from game state: " + std::string(e.what()));
    }

    return {turn, playerID};
}

/// Extract civilization and leader info from game state JSON
std::pair<std::string, std::string> ExtractCivInfo(const std::string& gameStateJson)
{
    std::string civType = "Unknown";
    std::string leaderType = "Unknown";

    try
    {
        json gameState = json::parse(gameStateJson);

        if (gameState.contains("player"))
        {
            auto& player = gameState["player"];

            if (player.contains("civilizationType"))
            {
                civType = player["civilizationType"].get<std::string>();

                // Clean up the type name (e.g., "CIVILIZATION_ROME" -> "Rome")
                if (civType.find("CIVILIZATION_") == 0)
                {
                    civType = civType.substr(13); // Remove "CIVILIZATION_"

                    if (!civType.empty())
                    {
                        civType[0] = static_cast<char>(toupper(civType[0]));
                        for (size_t i = 1; i < civType.length(); i++)
                        {
                            civType[i] = static_cast<char>(tolower(civType[i]));
                        }
                        // Capitalize after underscores
                        for (size_t i = 1; i < civType.length(); i++)
                        {
                            if (civType[i - 1] == '_')
                            {
                                civType[i] = static_cast<char>(toupper(civType[i]));
                            }
                        }
                        // Remove underscores
                        civType.erase(
                            std::remove(civType.begin(), civType.end(), '_'),
                            civType.end());
                    }
                }
            }

            if (player.contains("leaderType"))
            {
                leaderType = player["leaderType"].get<std::string>();

                // Clean up leader name (e.g., "LEADER_TRAJAN" -> "Trajan")
                if (leaderType.find("LEADER_") == 0)
                {
                    leaderType = leaderType.substr(7); // Remove "LEADER_"

                    if (!leaderType.empty())
                    {
                        leaderType[0] = static_cast<char>(toupper(leaderType[0]));
                        for (size_t i = 1; i < leaderType.length(); i++)
                        {
                            leaderType[i] = static_cast<char>(tolower(leaderType[i]));
                        }
                        for (size_t i = 1; i < leaderType.length(); i++)
                        {
                            if (leaderType[i - 1] == '_')
                            {
                                leaderType[i] = static_cast<char>(toupper(leaderType[i]));
                            }
                        }
                        leaderType.erase(
                            std::remove(leaderType.begin(), leaderType.end(), '_'),
                            leaderType.end());
                    }
                }
            }
        }
    }
    catch (const json::exception& e)
    {
        Log("Warning: Could not extract civ info from game state: " + std::string(e.what()));
    }

    return {civType, leaderType};
}

} // anonymous namespace

// ============================================================================
// SYSTEM PROMPT
// ============================================================================

namespace
{

/// Get the path to the system prompt file in the mod folder
std::string GetSystemPromptPath()
{
    char documentsPath[MAX_PATH];
    if (SUCCEEDED(SHGetFolderPathA(nullptr, CSIDL_PERSONAL, nullptr, 0, documentsPath)))
    {
        return std::string(documentsPath) +
            "\\My Games\\Sid Meier's Civilization VI\\Mods\\ClaudeAI\\system_prompt.txt";
    }
    return "";
}

/// Load system prompt from file and substitute placeholders
std::string BuildSystemPrompt(const std::string& civType, const std::string& leaderType)
{
    std::string promptPath = GetSystemPromptPath();
    std::string prompt;

    // Try to load from file
    if (!promptPath.empty())
    {
        std::ifstream file(promptPath);
        if (file.is_open())
        {
            std::stringstream buffer;
            buffer << file.rdbuf();
            prompt = buffer.str();
            Log("Loaded system prompt from: " + promptPath);
        }
        else
        {
            Log("WARNING: Could not open system prompt file: " + promptPath);
        }
    }

    // Use fallback if file loading failed
    if (prompt.empty())
    {
        Log("Using fallback system prompt");
        prompt = "You are an AI playing Civilization VI as {LEADER_NAME} of {CIV_NAME}. "
                 "Respond with a JSON object containing an 'actions' array. "
                 "Valid actions: move_unit, attack, found_city, build, research, civic, end_turn. "
                 "Always end with {\"action\": \"end_turn\"}. "
                 "Respond ONLY with JSON, no explanation.";
    }

    // Replace placeholders
    prompt = ReplaceAll(prompt, "{CIV_NAME}", civType);
    prompt = ReplaceAll(prompt, "{LEADER_NAME}", leaderType);

    return prompt;
}

} // anonymous namespace

// ============================================================================
// PUBLIC API - INITIALIZATION
// ============================================================================

bool Initialize()
{
    Log("Claude API initialization");

    if (g_apiKey.empty())
    {
        char* envKey = nullptr;
        size_t len = 0;

        if (_dupenv_s(&envKey, &len, "ANTHROPIC_API_KEY") == 0 && envKey != nullptr)
        {
            g_apiKey = std::string(envKey);
            free(envKey);
            Log("Claude API key loaded from environment variable");
        }
        else
        {
            Log("ERROR: Claude API key not found in environment variable 'ANTHROPIC_API_KEY'");
            return false;
        }
    }

    return true;
}

void ResetTurnTracking()
{
    Log("Resetting Claude API turn tracking");
    g_lastQueriedTurn = -1;
    g_lastQueriedPlayer = -1;
    g_cachedResponse.clear();
}

bool TestConnection()
{
    Log("Testing Claude API connection...");

    if (!Initialize())
    {
        Log("ERROR: Failed to initialize Claude API");
        return false;
    }

    // Build simple test request
    json requestBody;
    requestBody["model"] = g_model;
    requestBody["max_tokens"] = kMaxTestResponseTokens;
    requestBody["messages"] = json::array({
        {{"role", "user"}, {"content", "Reply with exactly: CONNECTION_OK"}}
    });

    std::string body = requestBody.dump();
    std::string response = HttpPost(kApiHost, kApiPath, body, g_apiKey);

    if (response.empty())
    {
        Log("ERROR: Empty response from Claude API test");
        return false;
    }

    try
    {
        json responseJson = json::parse(response);

        if (responseJson.contains("error"))
        {
            std::string errorMsg = responseJson["error"]["message"].get<std::string>();
            Log("Claude API test failed: " + errorMsg);
            return false;
        }

        if (responseJson.contains("content") &&
            responseJson["content"].is_array() &&
            !responseJson["content"].empty())
        {
            std::string content = responseJson["content"][0]["text"].get<std::string>();
            Log("Claude API test response: " + content);
            Log("Claude API connection test SUCCESSFUL!");
            return true;
        }

        Log("ERROR: Unexpected response format in test");
        return false;
    }
    catch (const json::exception& e)
    {
        Log("ERROR: Failed to parse test response: " + std::string(e.what()));
        return false;
    }
}

// ============================================================================
// PUBLIC API - BLOCKING REQUEST
// ============================================================================

std::string GetActionFromClaude(const std::string& gameStateJson)
{
    Log("GetActionFromClaude called");

    if (g_apiKey.empty())
    {
        Log("ERROR: API key not set. Call Initialize() first.");
        return R"({"error":"API key not set"})";
    }

    // Extract turn and player info for rate limiting
    auto [currentTurn, currentPlayer] = ExtractTurnAndPlayer(gameStateJson);
    Log("Turn: " + std::to_string(currentTurn) + ", Player: " + std::to_string(currentPlayer));

    // Check if we've already queried for this turn/player
    if (currentTurn >= 0 && currentPlayer >= 0)
    {
        if (currentTurn == g_lastQueriedTurn && currentPlayer == g_lastQueriedPlayer)
        {
            Log("Already queried Claude for turn " + std::to_string(currentTurn) +
                " player " + std::to_string(currentPlayer) + ", returning cached response");

            if (!g_cachedResponse.empty())
            {
                return g_cachedResponse;
            }
            return R"({"action":"end_turn","reason":"Already queried this turn"})";
        }
    }

    // Extract civilization info from game state
    auto [civType, leaderType] = ExtractCivInfo(gameStateJson);
    Log("Playing as: " + leaderType + " of " + civType);

    // Build request
    std::string systemPrompt = BuildSystemPrompt(civType, leaderType);

    json requestBody;
    requestBody["model"] = g_model;
    requestBody["max_tokens"] = g_maxTokens;
    requestBody["system"] = systemPrompt;
    requestBody["messages"] = json::array({
        {{"role", "user"}, {"content", "Current game state:\n" + gameStateJson + "\n\nWhat is your next action?"}}
    });

    std::string body = requestBody.dump();
    Log("Sending request to Claude API...");

    // Make the API call
    std::string response = HttpPost(kApiHost, kApiPath, body, g_apiKey);

    if (response.empty())
    {
        Log("ERROR: Empty response from Claude API");
        return R"({"error":"Empty response"})";
    }

    Log("Received response from Claude API (" + std::to_string(response.size()) + " bytes)");

    // Parse the response
    try
    {
        json responseJson = json::parse(response);

        // Check for API error
        if (responseJson.contains("error"))
        {
            std::string errorMsg = responseJson["error"]["message"].get<std::string>();
            Log("Claude API error: " + errorMsg);
            return R"({"error":")" + EscapeJson(errorMsg) + R"("})";
        }

        // Extract content
        if (responseJson.contains("content") &&
            responseJson["content"].is_array() &&
            !responseJson["content"].empty())
        {
            std::string content = responseJson["content"][0]["text"].get<std::string>();
            Log("Claude raw response: " + content);

            std::string result;
            std::string jsonStr = ExtractJsonFromResponse(content);

            if (!jsonStr.empty())
            {
                try
                {
                    json actionJson = json::parse(jsonStr);
                    result = actionJson.dump();
                    Log("Successfully parsed action: " + result);
                }
                catch (const json::exception& e)
                {
                    Log("Warning: Extracted text was not valid JSON: " + std::string(e.what()));
                    Log("Extracted text was: " + jsonStr);
                    result = R"({"action":"end_turn","reason":"Invalid JSON from Claude"})";
                }
            }
            else
            {
                Log("Warning: Could not extract JSON from Claude response");
                result = R"({"action":"end_turn","reason":")" + EscapeJson(content) + R"("})";
            }

            // Cache response and update turn tracking
            g_lastQueriedTurn = currentTurn;
            g_lastQueriedPlayer = currentPlayer;
            g_cachedResponse = result;

            Log("Cached response for turn " + std::to_string(currentTurn) +
                " player " + std::to_string(currentPlayer));

            return result;
        }

        Log("ERROR: Unexpected response format from Claude API");
        return R"({"error":"Unexpected response format"})";
    }
    catch (const json::exception& e)
    {
        Log("ERROR: Failed to parse Claude API response: " + std::string(e.what()));
        Log("Raw response: " + response.substr(0, kMaxJsonPreviewLength));
        return R"({"error":"JSON parse error"})";
    }
}

// ============================================================================
// PUBLIC API - ASYNC REQUEST
// ============================================================================

namespace
{

/// Background worker function for async requests
void AsyncWorkerThread(std::string gameStateJson)
{
    Log("[ASYNC] Worker thread started");

    try
    {
        // Check if cancelled before starting
        if (g_asyncCancelled.load())
        {
            Log("[ASYNC] Request cancelled before starting");
            std::lock_guard<std::mutex> lock(g_asyncMutex);
            g_asyncState.store(AsyncState::Idle);
            return;
        }

        // Call the blocking function
        std::string result = GetActionFromClaude(gameStateJson);

        // Check if cancelled after completion
        if (g_asyncCancelled.load())
        {
            Log("[ASYNC] Request cancelled after completion");
            std::lock_guard<std::mutex> lock(g_asyncMutex);
            g_asyncState.store(AsyncState::Idle);
            return;
        }

        // Store the result
        {
            std::lock_guard<std::mutex> lock(g_asyncMutex);
            g_asyncResponse = result;

            // Check if it's an error response
            try
            {
                json resultJson = json::parse(result);
                if (resultJson.contains("error"))
                {
                    g_asyncError = resultJson["error"].get<std::string>();
                    g_asyncState.store(AsyncState::Failed);
                    Log("[ASYNC] Request completed with error: " + g_asyncError);
                }
                else
                {
                    g_asyncState.store(AsyncState::Ready);
                    Log("[ASYNC] Request completed successfully");
                }
            }
            catch (...)
            {
                g_asyncState.store(AsyncState::Ready);
                Log("[ASYNC] Request completed (response not parsed)");
            }
        }
    }
    catch (const std::exception& e)
    {
        std::lock_guard<std::mutex> lock(g_asyncMutex);
        g_asyncError = std::string("Exception: ") + e.what();
        g_asyncState.store(AsyncState::Failed);
        Log("[ASYNC] Worker thread exception: " + g_asyncError);
    }

    Log("[ASYNC] Worker thread finished");
}

} // anonymous namespace

bool StartAsyncRequest(const std::string& gameStateJson)
{
    Log("[ASYNC] StartAsyncRequest called");

    // Check current state
    AsyncState currentState = g_asyncState.load();
    if (currentState == AsyncState::Pending)
    {
        Log("[ASYNC] Request already pending, ignoring new request");
        return false;
    }

    // Join previous thread if it exists
    if (g_asyncThread.joinable())
    {
        Log("[ASYNC] Joining previous thread");
        g_asyncThread.join();
    }

    // Initialize if needed
    if (g_apiKey.empty())
    {
        if (!Initialize())
        {
            Log("[ASYNC] Failed to initialize API");
            std::lock_guard<std::mutex> lock(g_asyncMutex);
            g_asyncError = "Failed to initialize API";
            g_asyncState.store(AsyncState::Failed);
            return false;
        }
    }

    // Reset state
    {
        std::lock_guard<std::mutex> lock(g_asyncMutex);
        g_asyncResponse.clear();
        g_asyncError.clear();
        g_asyncCancelled.store(false);
        g_asyncState.store(AsyncState::Pending);
    }

    // Start worker thread
    Log("[ASYNC] Starting worker thread");
    g_asyncThread = std::thread(AsyncWorkerThread, gameStateJson);

    return true;
}

AsyncState GetAsyncState()
{
    return g_asyncState.load();
}

std::string GetAsyncResponse()
{
    std::lock_guard<std::mutex> lock(g_asyncMutex);

    if (g_asyncState.load() != AsyncState::Ready)
    {
        return "";
    }

    std::string response = std::move(g_asyncResponse);
    g_asyncResponse.clear();
    g_asyncState.store(AsyncState::Idle);

    Log("[ASYNC] Response retrieved, state reset to Idle");
    return response;
}

std::string GetAsyncError()
{
    std::lock_guard<std::mutex> lock(g_asyncMutex);
    return g_asyncError;
}

void CancelAsyncRequest()
{
    Log("[ASYNC] CancelAsyncRequest called");

    g_asyncCancelled.store(true);

    // Wait for thread to finish
    if (g_asyncThread.joinable())
    {
        Log("[ASYNC] Waiting for thread to finish");
        g_asyncThread.join();
    }

    std::lock_guard<std::mutex> lock(g_asyncMutex);
    g_asyncState.store(AsyncState::Idle);
    g_asyncResponse.clear();
    g_asyncError.clear();

    Log("[ASYNC] Request cancelled and state reset");
}

} // namespace ClaudeAPI
