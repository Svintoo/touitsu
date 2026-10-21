#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <mmsystem.h>
#include <string>
#include <cstdlib>
#include <cstring>

namespace {
struct InternetHandle { HINTERNET h; ~InternetHandle() { if (h) WinHttpCloseHandle(h); } };
bool allowedHost(const std::wstring& host) {
    return host == L"jisho.org" || host == L"www.jisho.org" || host == L"assets.languagepod101.com" ||
        (host.size() > 15 && host.compare(host.size() - 15, 15, L".cloudfront.net") == 0);
}
}

// Called only on the pronunciation worker, after the user's opt-in.
extern "C" int touitsu_pronunciation_get(const wchar_t* url, char** output, size_t* length) {
    *output = nullptr; *length = 0;
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwSchemeLength = parts.dwHostNameLength = parts.dwUrlPathLength = parts.dwExtraInfoLength = DWORD(-1);
    if (!WinHttpCrackUrl(url, 0, 0, &parts) || parts.nScheme != INTERNET_SCHEME_HTTPS ||
        parts.nPort != INTERNET_DEFAULT_HTTPS_PORT || parts.dwUserNameLength || parts.dwPasswordLength) return 1;
    std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
    for (auto& c : host) if (c >= L'A' && c <= L'Z') c += L'a' - L'A';
    if (!allowedHost(host)) return 1;
    std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
    path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
    InternetHandle session{WinHttpOpen(L"Touitsu/1.0 pronunciation", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0)};
    if (!session.h) return 2;
    WinHttpSetTimeouts(session.h, 2000, 3000, 3000, 3000);
    InternetHandle connection{WinHttpConnect(session.h, host.c_str(), parts.nPort, 0)};
    if (!connection.h) return 2;
    InternetHandle request{WinHttpOpenRequest(connection.h, L"GET", path.c_str(), nullptr,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE)};
    if (!request.h) return 2;
    DWORD policy = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    WinHttpSetOption(request.h, WINHTTP_OPTION_REDIRECT_POLICY, &policy, sizeof(policy));
    DWORD disabled = WINHTTP_DISABLE_COOKIES;
    WinHttpSetOption(request.h, WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled));
    if (!WinHttpSendRequest(request.h, WINHTTP_NO_ADDITIONAL_HEADERS, 0, nullptr, 0, 0, 0) ||
        !WinHttpReceiveResponse(request.h, nullptr)) return 2;
    DWORD status = 0, status_length = sizeof(status);
    if (!WinHttpQueryHeaders(request.h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX, &status, &status_length, WINHTTP_NO_HEADER_INDEX) || status != 200) return 3;
    const auto started = GetTickCount64();
    std::string response;
    for (;;) {
        if (GetTickCount64() - started > 10000) return 2;
        char chunk[8192]; DWORD count = 0;
        if (!WinHttpReadData(request.h, chunk, sizeof(chunk), &count)) return 2;
        if (!count) break;
        if (response.size() + count > 2 * 1024 * 1024) return 4;
        response.append(chunk, count);
    }
    auto* copy = static_cast<char*>(malloc(response.size() + 1));
    if (!copy) return 5;
    memcpy(copy, response.data(), response.size()); copy[response.size()] = 0;
    *output = copy; *length = response.size();
    return 0;
}
extern "C" void touitsu_pronunciation_free(char* data) { free(data); }
extern "C" void touitsu_pronunciation_stop() { mciSendStringW(L"stop touitsuPronunciation", nullptr, 0, nullptr); }

extern "C" int touitsu_pronunciation_play(const char* data, size_t length, bool (*cancelled)(void*), void* context) {
    if (cancelled(context)) return 0;
    if (!length || length > 2 * 1024 * 1024) return 1;
    wchar_t folder[MAX_PATH], path[MAX_PATH];
    if (!GetTempPathW(MAX_PATH, folder) || !GetTempFileNameW(folder, L"tua", 0, path)) return 1;
    const auto cleanup = [&] { DeleteFileW(path); };
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (file == INVALID_HANDLE_VALUE) { cleanup(); return 1; }
    DWORD written = 0;
    const bool saved = WriteFile(file, data, DWORD(length), &written, nullptr) && written == length;
    CloseHandle(file);
    if (!saved) { cleanup(); return 1; }
    std::wstring command = L"open \"" + std::wstring(path) + L"\" type mpegvideo alias touitsuPronunciation";
    if (mciSendStringW(command.c_str(), nullptr, 0, nullptr)) { cleanup(); return 1; }
    int result = 0;
    if (cancelled(context)) { mciSendStringW(L"close touitsuPronunciation", nullptr, 0, nullptr); cleanup(); return 0; }
    if (mciSendStringW(L"play touitsuPronunciation", nullptr, 0, nullptr)) result = 1;
    const auto started = GetTickCount64();
    while (!result && !cancelled(context) && GetTickCount64() - started < 30000) {
        wchar_t mode[32]{};
        if (mciSendStringW(L"status touitsuPronunciation mode", mode, 32, nullptr) || wcscmp(mode, L"playing")) break;
        Sleep(40);
    }
    mciSendStringW(L"close touitsuPronunciation", nullptr, 0, nullptr);
    cleanup();
    return result;
}
