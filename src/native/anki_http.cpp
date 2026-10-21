#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <string>
#include <cstdlib>
#include <cstring>

struct InternetHandle {
    HINTERNET h;
    ~InternetHandle() { if (h) WinHttpCloseHandle(h); }
};

// Synchronous only on Touitsu's Anki worker. Never called on the UI thread.
extern "C" int touitsu_anki_post(const wchar_t* url, const char* body, size_t length,
                                char** output, size_t* output_length) {
    *output = nullptr;
    *output_length = 0;
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwSchemeLength = parts.dwHostNameLength = parts.dwUrlPathLength = parts.dwExtraInfoLength = DWORD(-1);
    if (!WinHttpCrackUrl(url, 0, 0, &parts) ||
        (parts.nScheme != INTERNET_SCHEME_HTTP && parts.nScheme != INTERNET_SCHEME_HTTPS) ||
        length > 4 * 1024 * 1024) return 1;
    std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
    std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
    path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
    if (path.empty()) path = L"/";
    InternetHandle session{WinHttpOpen(L"Touitsu/1.0", WINHTTP_ACCESS_TYPE_NO_PROXY,
                                      WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0)};
    if (!session.h) return 2;
    WinHttpSetTimeouts(session.h, 2000, 2000, 2000, 3000);
    InternetHandle connection{WinHttpConnect(session.h, host.c_str(), parts.nPort, 0)};
    if (!connection.h) return 2;
    InternetHandle request{WinHttpOpenRequest(connection.h, L"POST", path.c_str(), nullptr,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
        parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)};
    if (!request.h) return 2;
    DWORD policy = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    WinHttpSetOption(request.h, WINHTTP_OPTION_REDIRECT_POLICY, &policy, sizeof(policy));
    if (!WinHttpSendRequest(request.h, L"Content-Type: application/json; charset=utf-8\r\n", DWORD(-1),
                           (void*)body, DWORD(length), DWORD(length), 0) ||
        !WinHttpReceiveResponse(request.h, nullptr)) return 2;
    DWORD status = 0, status_length = sizeof(status);
    if (!WinHttpQueryHeaders(request.h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX, &status, &status_length, WINHTTP_NO_HEADER_INDEX) ||
        status != 200) return 3;
    std::string response;
    const auto started = GetTickCount64();
    for (;;) {
        if (GetTickCount64() - started > 10000) return 2;
        char chunk[8192];
        DWORD count = 0;
        if (!WinHttpReadData(request.h, chunk, sizeof(chunk), &count)) return 2;
        if (!count) break;
        if (response.size() + count > 2 * 1024 * 1024) return 4;
        response.append(chunk, count);
    }
    auto result = static_cast<char*>(malloc(response.size() + 1));
    if (!result) return 5;
    memcpy(result, response.data(), response.size());
    result[response.size()] = 0;
    *output = result;
    *output_length = response.size();
    return 0;
}
extern "C" void touitsu_anki_free(char* data) { free(data); }
