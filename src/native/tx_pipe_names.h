#pragma once
// Isolate installations as well as architectures, so a verification build cannot
// receive connections intended for the user's running application.
namespace touitsu_pipes {
inline void moduleMarker() {}
struct Names { std::wstring hook, host, available, connecting; };
inline const Names& names() {
    static const Names value = [] {
        HMODULE module = nullptr;
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(&moduleMarker), &module);
        wchar_t path[32768] = {};
        const auto size = GetModuleFileNameW(module, path, 32768);
        size_t end = size;
        while (end && path[end - 1] != L'\\' && path[end - 1] != L'/') --end;
        uint64_t hash = 14695981039346656037ull;
        for (size_t i = 0; i < end; ++i) {
            wchar_t ch = path[i];
            if (ch >= L'A' && ch <= L'Z') ch += L'a' - L'A';
            if (ch == L'/') ch = L'\\';
            hash = (hash ^ static_cast<uint16_t>(ch)) * 1099511628211ull;
        }
        const auto prefix = L"TOUITSU_" + std::to_wstring(hash) + (sizeof(void*) == 8 ? L"_64_" : L"_32_");
        return Names{ L"\\\\.\\pipe\\" + prefix + L"HOOK", L"\\\\.\\pipe\\" + prefix + L"HOST", prefix + L"PIPE_AVAILABLE", prefix + L"CONNECTING_PIPES" };
    }();
    return value;
}
}
#define HOOK_PIPE touitsu_pipes::names().hook.c_str()
#define HOST_PIPE touitsu_pipes::names().host.c_str()
#define PIPE_AVAILABLE_EVENT touitsu_pipes::names().available.c_str()
#define CONNECTING_MUTEX touitsu_pipes::names().connecting.c_str()
